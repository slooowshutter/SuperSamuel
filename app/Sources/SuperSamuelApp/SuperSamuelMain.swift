import AppKit
import Darwin

@main
@MainActor
struct SuperSamuelMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "benchmark" {
            let exitCode = await BenchmarkCommand.run(
                arguments: Array(arguments.dropFirst())
            )
            exit(exitCode)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
