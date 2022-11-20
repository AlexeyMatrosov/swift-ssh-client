import Foundation
import NIO
import NIOCore

public final class SFTPClient {

    private let updateQueue: DispatchQueue
    private var sftpChannel: SFTPChannel

    // MARK: - Life Cycle

    init(sftpChannel: SFTPChannel,
         updateQueue: DispatchQueue) {
        self.sftpChannel = sftpChannel
        self.updateQueue = updateQueue
    }

    // MARK: - Public

    public func listDirectory(atPath path: String,
                              completion: @escaping ((Result<[SFTPPathComponent], Error>) -> Void)) {
        let newPath = recursivelyExecute(
            { path in
                return self.sftpChannel.realpath(path: path).map {
                    $0.components.first?.filename ?? ""
                }
            },
            merge: { new, current in
                return (new, new != current)
            },
            response: path
        )
        newPath.flatMap { path in
            return self.sftpChannel.openDir(path: path)
        }
        .flatMap { (handle: SFTPMessage.Handle) in
            self.recursivelyExecute(
                { (names: [SFTPPathComponent]) in
                    return self.sftpChannel.readDir(handle.handle)
                },
                merge: { (response: SFTPMessage.ReadDir.Response, current: [SFTPPathComponent]) in
                    switch response {
                    case let .name(name):
                        return (current + name.components, true)
                    case .status:
                        return (current, false)
                    }
                },
                response: []
            )
        }
        .whenComplete(on: updateQueue, completion)
    }

    public func getAttributes(at filePath: String,
                              completion: @escaping ((Result<SFTPFileAttributes, Error>) -> Void)) {
        sftpChannel.stat(path: filePath)
            .map { $0.attributes }
            .whenComplete(on: updateQueue, completion)
    }

    public func openFile(filePath: String,
                         flags: SFTPOpenFileFlags,
                         attributes: SFTPFileAttributes = .none,
                         updateQueue: DispatchQueue = .main,
                         completion: @escaping (Result<SFTPFile, Error>) -> Void) {
        let message = SFTPMessage.OpenFile.Payload(
            filePath: filePath,
            pFlags: flags,
            attributes: attributes
        )
        return sftpChannel.openFile(message)
            .map { handle in
                return SFTPFile(
                    channel: self.sftpChannel,
                    path: filePath,
                    handle: handle.handle,
                    updateQueue: updateQueue
                )
            }
            .whenComplete(on: updateQueue, completion)
    }

    public func withFile(filePath: String,
                         flags: SFTPOpenFileFlags,
                         attributes: SFTPFileAttributes = .none,
                         _ closure: @escaping (SFTPFile, @escaping () -> Void) -> Void,
                         completion: @escaping (Result<Void, Error>) -> Void) {
        openFile(
            filePath: filePath,
            flags: flags,
            attributes: attributes,
            updateQueue: .global(qos: .utility)
        ) { result in
            switch result {
            case let .failure(error):
                completion(.failure(error))
            case let .success(file):
                closure(file) {
                    file.close(completion: completion)
                }
            }
        }
    }

    public func createDirectory(atPath path: String,
                                attributes: SFTPFileAttributes = .none,
                                completion: @escaping ((Result<Void, Error>) -> Void)) {
        let message = SFTPMessage.MkDir.Payload(
            filePath: path,
            attributes: attributes
        )
        return sftpChannel.mkdir(message)
            .mapAsVoid()
            .whenComplete(on: updateQueue, completion)
    }

    public func moveItem(atPath current: String,
                         toPath destination: String,
                         completion: @escaping ((Result<Void, Error>) -> Void)) {
        let message = SFTPMessage.Rename.Payload(oldPath: current, newPath: destination)
        return sftpChannel.rename(message)
            .mapAsVoid()
            .whenComplete(on: updateQueue, completion)
    }

    public func removeDirectory(atPath path: String,
                                completion: @escaping ((Result<Void, Error>) -> Void)) {
        return sftpChannel.rmdir(path: path)
            .mapAsVoid()
            .whenComplete(on: updateQueue, completion)
    }

    public func removeFile(atPath path: String,
                           completion: @escaping ((Result<Void, Error>) -> Void)) {
        sftpChannel
            .rmFile(path: path)
            .mapAsVoid()
            .whenComplete(on: updateQueue, completion)
    }

    public func close(completion: @escaping () -> Void) {
        sftpChannel
            .close()
            .whenComplete(on: updateQueue) { _ in
                completion()
            }
    }

    // MARK: - Private

    private func recursivelyExecute<T, R>(_ future: @escaping (R) -> EventLoopFuture<T>,
                                          merge: @escaping (T, R) -> (R, Bool),
                                          response: R) -> EventLoopFuture<R> {
        let currentFuture = future(response)
        return currentFuture.flatMap { current in
            let (response, shouldContinue) = merge(current, response)
            if shouldContinue {
                return self.recursivelyExecute(
                    future,
                    merge: merge,
                    response: response
                )
            } else {
                return currentFuture.map { _ in response }
            }
        }
    }
}
