package main

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"flowriver/server/internal/adminapi"
	"flowriver/server/internal/config"
	"flowriver/server/internal/httpapi"
	"flowriver/server/internal/jobs"
	"flowriver/server/internal/mailer"
	"flowriver/server/internal/migrate"
	"flowriver/server/internal/secure"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/term"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)
	// mail-ingest 由 Postfix 管道调用,运行环境没有完整配置;在加载配置前短路。
	if len(os.Args) > 1 && os.Args[1] == "mail-ingest" {
		if err := runMailIngest(context.Background(), os.Args[1:]); err != nil {
			logger.Error("mail-ingest failed", "error", err.Error())
			os.Exit(1)
		}
		return
	}
	var cfg config.Config
	var err error
	if len(os.Args) > 1 && os.Args[1] == "admin" {
		cfg, err = config.LoadAdminOnly()
	} else {
		cfg, err = config.Load()
	}
	if err != nil {
		logger.Error("configuration invalid", "error", err.Error())
		os.Exit(2)
	}

	poolConfig, err := pgxpool.ParseConfig(cfg.DatabaseURL)
	if err != nil {
		logger.Error("database URL invalid")
		os.Exit(2)
	}
	poolConfig.MaxConns = 5
	poolConfig.MinConns = 0
	poolConfig.MaxConnLifetime = 30 * time.Minute
	poolConfig.MaxConnIdleTime = 5 * time.Minute
	poolConfig.ConnConfig.RuntimeParams["timezone"] = "UTC"
	poolConfig.ConnConfig.RuntimeParams["statement_timeout"] = "5000"
	poolConfig.ConnConfig.RuntimeParams["lock_timeout"] = "1000"

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	pool, err := pgxpool.NewWithConfig(ctx, poolConfig)
	if err != nil {
		logger.Error("database connection failed")
		os.Exit(1)
	}
	defer pool.Close()
	if err := pool.Ping(ctx); err != nil {
		logger.Error("database is unavailable")
		os.Exit(1)
	}
	migrationContext, migrationCancel := context.WithTimeout(ctx, 30*time.Second)
	if err := migrate.Apply(migrationContext, pool); err != nil {
		migrationCancel()
		logger.Error("database migration failed", "error", err.Error())
		os.Exit(1)
	}
	migrationCancel()

	if len(os.Args) > 1 {
		if err := runAdminCommand(ctx, os.Args[1:], pool, cfg, logger); err != nil {
			fmt.Fprintln(os.Stderr, "admin command failed:", err)
			os.Exit(1)
		}
		return
	}

	var sender mailer.Sender
	if cfg.EmailMode == "console" {
		sender = mailer.ConsoleSender{Logf: logger.Warn}
	} else {
		sender = mailer.SMTPSender{Address: cfg.SMTPAddr, TLSMode: cfg.SMTPTLSMode, Username: cfg.SMTPUsername, Password: cfg.SMTPPassword, From: cfg.SMTPFrom}
	}
	api, err := httpapi.New(pool, cfg, sender, logger)
	if err != nil {
		logger.Error("API initialization failed", "error", err.Error())
		os.Exit(1)
	}
	var admin *adminapi.API
	var adminServer *http.Server
	var adminListener net.Listener
	if cfg.AdminEnabled {
		admin, err = adminapi.New(pool, cfg, logger, sender)
		if err != nil {
			logger.Error("administrator console initialization failed", "error", err.Error())
			os.Exit(1)
		}
		adminListener, err = net.Listen("tcp", cfg.AdminListenAddr)
		if err != nil {
			logger.Error("administrator console listen failed", "error", err.Error())
			os.Exit(1)
		}
		adminServer = &http.Server{Addr: cfg.AdminListenAddr, Handler: admin.Handler(), ReadHeaderTimeout: 5 * time.Second,
			ReadTimeout: 10 * time.Second, WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10}
		go admin.RunMaintenance(ctx)
	}
	worker := &jobs.EmailWorker{DB: pool, Box: mustBox(cfg.OutboxEncryptionKey), Sender: sender, Log: logger}
	go worker.Run(ctx)
	if journal := api.SecurityJournal(); journal != nil {
		go (&jobs.SecurityWorker{DB: pool, Journal: journal, Box: mustBox(cfg.OutboxEncryptionKey), Log: logger}).Run(ctx)
	}
	if provider := api.AppleTokenRevoker(); provider != nil {
		go (&jobs.AppleRevokeWorker{DB: pool, Box: mustBox(cfg.OutboxEncryptionKey), Apple: provider, Log: logger}).Run(ctx)
	}

	server := &http.Server{
		Addr: cfg.ListenAddr, Handler: api.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       45 * time.Second,
		WriteTimeout:      45 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    32 << 10,
	}
	listener, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		logger.Error("API listen failed", "error", err.Error())
		os.Exit(1)
	}
	serveErr := make(chan error, 2)
	go func() {
		logger.Info("FlowRiver account API starting", "address", cfg.ListenAddr, "environment", cfg.Environment)
		serveErr <- server.Serve(listener)
	}()
	if adminServer != nil {
		go func() {
			logger.Info("FlowRiver administrator console starting", "address", cfg.AdminListenAddr)
			serveErr <- adminServer.Serve(adminListener)
		}()
	}
	serverCount := 1
	if adminServer != nil {
		serverCount++
	}
	select {
	case err := <-serveErr:
		if !errors.Is(err, http.ErrServerClosed) {
			logger.Error("HTTP service stopped", "error", err.Error())
			shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			_ = server.Shutdown(shutdown)
			if adminServer != nil {
				_ = adminServer.Shutdown(shutdown)
			}
			os.Exit(1)
		}
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			logger.Error("API shutdown failed", "error", err.Error())
			os.Exit(1)
		}
		if adminServer != nil {
			if err := adminServer.Shutdown(shutdown); err != nil {
				logger.Error("administrator console shutdown failed", "error", err.Error())
				os.Exit(1)
			}
		}
		for range serverCount {
			<-serveErr
		}
	}
}

func runAdminCommand(ctx context.Context, args []string, pool *pgxpool.Pool, cfg config.Config, logger *slog.Logger) error {
	if len(args) < 2 || len(args) > 3 || args[0] != "admin" {
		return errors.New("usage: flowriver-api admin bootstrap USERNAME | reset-totp USERNAME | reset-password USERNAME | status")
	}
	switch args[1] {
	case "serve":
		if len(args) != 2 {
			return errors.New("usage: flowriver-api admin serve")
		}
		return serveAdminOnly(ctx, pool, cfg, logger)
	case "bootstrap":
		if len(args) != 3 {
			return errors.New("usage: flowriver-api admin bootstrap USERNAME")
		}
		password, err := readPasswordTwice()
		if err != nil {
			return err
		}
		defer clear(password)
		uri, err := adminapi.CreateFirstAdmin(ctx, pool, cfg, args[2], string(password))
		if err != nil {
			return err
		}
		fmt.Println("One-time authenticator enrollment URI. Store it privately; it cannot be read back:")
		fmt.Println(uri)
		return nil
	case "reset-totp":
		if len(args) != 3 {
			return errors.New("usage: flowriver-api admin reset-totp USERNAME")
		}
		uri, err := adminapi.ResetAdminTOTP(ctx, pool, cfg, args[2])
		if err != nil {
			return err
		}
		fmt.Println("New one-time authenticator enrollment URI. All current administrator sessions were revoked:")
		fmt.Println(uri)
		return nil
	case "reset-password":
		if len(args) != 3 {
			return errors.New("usage: flowriver-api admin reset-password USERNAME")
		}
		password, err := readPasswordTwice()
		if err != nil {
			return err
		}
		defer clear(password)
		if err := adminapi.ResetAdminPassword(ctx, pool, cfg, args[2], string(password)); err != nil {
			return err
		}
		fmt.Println("Administrator password reset; all existing management sessions were revoked.")
		return nil
	case "status":
		if len(args) != 2 {
			return errors.New("usage: flowriver-api admin status")
		}
		var count int
		var username string
		err := pool.QueryRow(ctx, `SELECT count(*)::int,min(username) FROM admin_accounts WHERE disabled_at IS NULL`).Scan(&count, &username)
		if err != nil {
			return err
		}
		if count == 0 {
			fmt.Println("No active administrator. Run the one-time bootstrap command over SSH.")
			return nil
		}
		if count != 1 {
			return errors.New("multiple administrators exist; inspect the administrator account database")
		}
		fmt.Println("Administrator:", strings.TrimSpace(username), "| MFA: enabled | Console:", cfg.AdminOrigin)
		return nil
	default:
		return errors.New("usage: flowriver-api admin bootstrap USERNAME | reset-totp USERNAME | reset-password USERNAME | status")
	}
}

func serveAdminOnly(ctx context.Context, pool *pgxpool.Pool, cfg config.Config, logger *slog.Logger) error {
	var sender mailer.Sender
	if cfg.EmailMode == "smtp" {
		sender = mailer.SMTPSender{Address: cfg.SMTPAddr, TLSMode: cfg.SMTPTLSMode, Username: cfg.SMTPUsername, Password: cfg.SMTPPassword, From: cfg.SMTPFrom}
	} else {
		sender = mailer.ConsoleSender{Logf: logger.Warn}
	}
	admin, err := adminapi.New(pool, cfg, logger, sender)
	if err != nil {
		return fmt.Errorf("administrator console initialization failed: %w", err)
	}
	listener, err := net.Listen("tcp", cfg.AdminListenAddr)
	if err != nil {
		return fmt.Errorf("administrator console listen failed: %w", err)
	}
	server := &http.Server{
		Addr: cfg.AdminListenAddr, Handler: admin.Handler(),
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second,
		WriteTimeout: 15 * time.Second, IdleTimeout: 60 * time.Second,
		MaxHeaderBytes: 32 << 10,
	}
	go admin.RunMaintenance(ctx)
	serveErr := make(chan error, 1)
	go func() {
		logger.Info("FlowRiver administrator console starting in admin-only mode", "address", cfg.AdminListenAddr)
		serveErr <- server.Serve(listener)
	}()
	select {
	case err := <-serveErr:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("administrator console stopped: %w", err)
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			return fmt.Errorf("administrator console shutdown failed: %w", err)
		}
		if err := <-serveErr; !errors.Is(err, http.ErrServerClosed) {
			return fmt.Errorf("administrator console stopped: %w", err)
		}
		return nil
	}
}

func readPasswordTwice() ([]byte, error) {
	fmt.Fprint(os.Stderr, "New administrator password (minimum 12 characters): ")
	password, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		return nil, errors.New("password must be entered from a terminal")
	}
	if len(password) < 12 || len(password) > 128 {
		clear(password)
		return nil, errors.New("password must be 12 to 128 bytes")
	}
	fmt.Fprint(os.Stderr, "Repeat administrator password: ")
	repeated, err := term.ReadPassword(int(os.Stdin.Fd()))
	fmt.Fprintln(os.Stderr)
	if err != nil {
		clear(password)
		return nil, errors.New("password must be entered from a terminal")
	}
	if subtle.ConstantTimeCompare(password, repeated) != 1 {
		clear(password)
		clear(repeated)
		return nil, errors.New("password entries do not match")
	}
	clear(repeated)
	return password, nil
}

func mustBox(key []byte) *secure.Box {
	box, err := secure.NewBox(key)
	if err != nil {
		panic("validated encryption key became invalid")
	}
	return box
}
