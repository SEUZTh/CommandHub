import XCTest
@testable import CommandHub

final class CommandParserTests: XCTestCase {
    func testParseRecognizesBasicCommands() {
        let input = """
        ls -la
        pwd
        cd /var/log
        echo "hello world"
        cat /etc/hosts
        """

        XCTAssertEqual(
            CommandParser.parse(input),
            [
                "ls -la",
                "pwd",
                "cd /var/log",
                "echo \"hello world\"",
                "cat /etc/hosts"
            ]
        )
    }

    func testParseFiltersCommentsAndNoiseFromMixedClipboardText() {
        let input = """
        # 查看 pod
        kubectl get pods

        # 查看日志
        kubectl logs my-pod

        some random text

        docker ps
        """

        XCTAssertEqual(
            CommandParser.parse(input),
            [
                "kubectl get pods",
                "kubectl logs my-pod",
                "docker ps"
            ]
        )
    }

    func testParseKeepsComplexShellCommandsIntact() {
        let input = """
        cd project && npm run dev
        git checkout main && git pull
        kubectl get pods | grep api
        cat file.txt | awk '{print $1}'
        """

        XCTAssertEqual(
            CommandParser.parse(input),
            [
                "cd project && npm run dev",
                "git checkout main && git pull",
                "kubectl get pods | grep api",
                "cat file.txt | awk '{print $1}'"
            ]
        )
    }

    func testParseSupportsSudoPrefixedCommands() {
        let input = """
        sudo kubectl get pods
        sudo apt update
        sudo systemctl restart nginx
        """

        XCTAssertEqual(
            CommandParser.parse(input),
            [
                "sudo kubectl get pods",
                "sudo apt update",
                "sudo systemctl restart nginx"
            ]
        )
    }

    func testParseRecognizesGitKubernetesAndDockerCommands() {
        let input = """
        git status
        git checkout -b feature/test
        git commit -m "fix bug"
        git push origin main
        git pull --rebase
        git log --oneline
        kubectl get pods -A
        kubectl describe pod my-pod
        kubectl logs my-pod -f
        kubectl exec -it my-pod -- /bin/bash
        kubectl delete pod my-pod
        docker ps
        docker images
        docker exec -it container /bin/bash
        docker build -t my-app .
        docker run -d -p 8080:80 nginx
        """

        XCTAssertEqual(
            CommandParser.parse(input),
            [
                "git status",
                "git checkout -b feature/test",
                "git commit -m \"fix bug\"",
                "git push origin main",
                "git pull --rebase",
                "git log --oneline",
                "kubectl get pods -A",
                "kubectl describe pod my-pod",
                "kubectl logs my-pod -f",
                "kubectl exec -it my-pod -- /bin/bash",
                "kubectl delete pod my-pod",
                "docker ps",
                "docker images",
                "docker exec -it container /bin/bash",
                "docker build -t my-app .",
                "docker run -d -p 8080:80 nginx"
            ]
        )
    }

    func testParseRejectsNoiseInput() {
        let input = """
        hello world
        this is not command
        123456
        a
        #
        """

        XCTAssertTrue(CommandParser.parse(input).isEmpty)
    }

    func testParsePreservesLongAndSpecialCharacterCommands() {
        let input = """
        kubectl get pods -n default --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'
        echo $PATH
        echo `date`
        echo "$(whoami)"
        grep "error" log.txt
        """

        XCTAssertEqual(
            CommandParser.parse(input),
            [
                "kubectl get pods -n default --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'",
                "echo $PATH",
                "echo `date`",
                "echo \"$(whoami)\"",
                "grep \"error\" log.txt"
            ]
        )
    }
}
