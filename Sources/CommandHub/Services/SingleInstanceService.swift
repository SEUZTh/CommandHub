import Foundation
import Darwin

final class SingleInstanceService {
    static let shared = SingleInstanceService()

    private var lockFileDescriptor: Int32 = -1

    private init() {}

    func acquire() -> Bool {
        if lockFileDescriptor != -1 {
            return true
        }

        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttt.CommandHub.lock", isDirectory: false)

        lockFileDescriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFileDescriptor != -1 else {
            return true
        }

        if flock(lockFileDescriptor, LOCK_EX | LOCK_NB) == 0 {
            return true
        }

        close(lockFileDescriptor)
        lockFileDescriptor = -1
        return false
    }

    func release() {
        guard lockFileDescriptor != -1 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    deinit {
        release()
    }
}
