import Foundation
import XCTest

@testable import RiverDiaryMac

final class GitActivityReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("river-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        super.tearDown()
    }

    func testDiscoversRepositoriesAndSkipsIgnoredDirectories() throws {
        try makeRepository(at: root.appendingPathComponent("alpha"))
        try makeRepository(at: root.appendingPathComponent("group/beta"))
        try makeRepository(at: root.appendingPathComponent("node_modules/ignored"))

        let repositories = GitActivityReader.discoverRepositories(root: root)
            .map(\.lastPathComponent)
            .sorted()
        XCTAssertEqual(repositories, ["alpha", "beta"])
    }

    func testRootItselfCanBeARepository() throws {
        let repository = root.appendingPathComponent("solo")
        try makeRepository(at: repository)
        let repositories = GitActivityReader.discoverRepositories(root: repository)
        XCTAssertEqual(repositories.map(\.lastPathComponent), ["solo"])
    }

    func testReadsTodaysCommitCount() throws {
        let repository = root.appendingPathComponent("project")
        try makeRepository(at: repository)
        try commitFile(in: repository, name: "one.txt", message: "first")

        let result = GitActivityReader.readToday(root: repository)
        XCTAssertEqual(result.repos.count, 1)
        XCTAssertEqual(result.repos.first?.name, "project")
        XCTAssertEqual(result.repos.first?.commits, 1)
        XCTAssertEqual(result.totalCommits, 1)
    }

    func testMissingRootReportsIssue() {
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let result = GitActivityReader.readToday(root: missing)
        XCTAssertTrue(result.repos.isEmpty)
        XCTAssertNotNil(result.issue)
    }

    private func makeRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".git"), withIntermediateDirectories: true)
    }

    private func commitFile(in repository: URL, name: String, message: String) throws {
        try runGit(["init"], in: repository)
        try runGit(["config", "user.email", "river-tests@example.com"], in: repository)
        try runGit(["config", "user.name", "River Tests"], in: repository)
        try Data("x".utf8).write(to: repository.appendingPathComponent(name))
        try runGit(["add", name], in: repository)
        try runGit(["commit", "-m", message], in: repository)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw XCTSkip("git is unavailable: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("git \(arguments.joined(separator: " ")) failed: \(output)")
            return
        }
    }
}
