import Foundation

/// Maps low-level Foundation / encryption errors into short, actionable messages
/// the user can actually read, while falling back to the system text when we do not
/// recognise the failure. This is the single place that translates errors to user
/// language so views never have to embed `error.localizedDescription` directly.
enum UserFacingError {
    static func message(for error: Error) -> String {
        if let encryption = error as? StateEncryptionError {
            switch encryption {
            case .decryptionFailed:
                return "本地日记解密失败，内容没有显示。可能是文件损坏，或更换过加密密钥。"
            case .malformedFile:
                return "本地状态文件格式不正确，无法读取。为避免覆盖，已停止写入。"
            case .keychainStatus:
                return "无法访问系统钥匙串。请退出后在“钥匙串访问”中允许本应用，再重新打开。"
            }
        }

        let ns = error as NSError
        switch ns.domain {
        case NSCocoaErrorDomain:
            switch ns.code {
            case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
                return "没有写入权限，内容未保存。请在“系统设置 → 隐私与安全性”中允许本应用访问存放位置。"
            case NSFileWriteOutOfSpaceError:
                return "磁盘空间不足，内容未保存。请清理后重试。"
            case NSFileWriteFileExistsError:
                return "目标位置已有同名文件，未覆盖。请换一个位置。"
            case NSFileReadNoSuchFileError, NSFileReadNoPermissionError:
                return "要读取的文件不存在或没有读取权限。请重新选择文件。"
            default:
                break
            }
        default:
            break
        }

        return error.localizedDescription
    }
}