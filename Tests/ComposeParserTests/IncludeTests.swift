import ComposeModel
import ComposeParser
import Foundation
import Testing

@Suite("include")
struct IncludeTests {
    @Test("Included services join the project and resolve paths against their own directory")
    func includedPaths() throws {
        let result = try Fixture.parse(
            """
            include:
              - stack/db.yaml
            services:
              web:
                image: nginx
                depends_on: [db]
            """,
            files: ["/project/stack/db.yaml": "services:\n  db:\n    image: postgres\n    volumes:\n      - ../data:/var/lib/data\n"]
        )
        let db = try #require(result.file.services["db"])
        #expect(db.mounts == [Service.Mount(source: .bind("/project/data"), target: "/var/lib/data")])
        #expect(result.file.services["web"]?.dependsOn.map(\.service) == ["db"])
    }

    @Test("Included files may depend on each other and on the including file")
    func crossReferences() throws {
        let result = try Fixture.parse(
            "include:\n  - a.yaml\n  - b.yaml\nservices:\n  web:\n    image: nginx\n",
            files: [
                "/project/a.yaml": "services:\n  a:\n    image: nginx\n    depends_on: [b, web]\n",
                "/project/b.yaml": "services:\n  b:\n    image: nginx\n",
            ]
        )
        #expect(result.file.services["a"]?.dependsOn.map(\.service) == ["b", "web"])

        let dangling = #expect(throws: ParseError.self) {
            try Fixture.parse(
                "include:\n  - a.yaml\nservices:\n  web:\n    image: nginx\n",
                files: ["/project/a.yaml": "services:\n  a:\n    image: nginx\n    depends_on: [nope]\n"]
            )
        }
        #expect(dangling?.reason == .undefinedReference)
        #expect(dangling?.mark?.file == "a.yaml")
    }

    @Test("Variables: the shell, then this project's .env, then the included project's own")
    func variablePrecedence() throws {
        let yaml = "include:\n  - sub/inc.yaml\nservices:\n  web:\n    image: nginx\n"
        let files = [
            "/project/sub/inc.yaml": "services:\n  inc:\n    image: \"inc:${FOO}-${BAR}\"\n",
            "/project/sub/.env": "FOO=sub\nBAR=subbar\n",
        ]
        let fromParent = try Fixture.parse(yaml, files: files, dotEnv: "FOO=parent\n")
        #expect(fromParent.file.services["inc"]?.image == "inc:parent-subbar")
        let fromShell = try Fixture.parse(yaml, environment: ["FOO": "shell"], files: files, dotEnv: "FOO=parent\n")
        #expect(fromShell.file.services["inc"]?.image == "inc:shell-subbar")
    }

    @Test("The long form takes a project directory, env files and a list of paths merged in order")
    func longForm() throws {
        let result = try Fixture.parse(
            """
            include:
              - path: [lib/base.yaml, lib/override.yaml]
                project_directory: lib/root
                env_file: lib/vars.env
            services:
              web:
                image: nginx
            """,
            files: [
                "/project/lib/base.yaml": "services:\n  api:\n    image: \"api:${TAG}\"\n    command: [serve]\n    volumes:\n      - ./a:/a\n",
                "/project/lib/override.yaml": "services:\n  api:\n    command: [serve, --debug]\n    environment:\n      MODE: debug\n",
                "/project/lib/vars.env": "TAG=7\n",
            ]
        )
        let api = try #require(result.file.services["api"])
        #expect(api.image == "api:7")
        #expect(api.command == ["serve", "--debug"])
        #expect(api.environment == ["MODE": "debug"])
        #expect(api.mounts == [Service.Mount(source: .bind("/project/lib/root/a"), target: "/a")])
    }

    @Test("Two different definitions of one name are refused; the same one twice is not")
    func conflicts() throws {
        let files = [
            "/project/one.yaml": "services:\n  shared:\n    image: nginx\n",
            "/project/two.yaml": "services:\n  shared:\n    image: redis\n",
        ]
        let clash = #expect(throws: ParseError.self) {
            try Fixture.parse("include:\n  - one.yaml\n  - two.yaml\nservices:\n  web:\n    image: nginx\n", files: files)
        }
        #expect(clash?.reason == .conflictingDefinition)
        #expect(clash?.problem.contains("`one.yaml:") == true)
        #expect(clash?.problem.contains("`two.yaml:") == true)

        let local = #expect(throws: ParseError.self) {
            try Fixture.parse("include:\n  - one.yaml\nservices:\n  shared:\n    image: busybox\n", files: files)
        }
        #expect(local?.reason == .conflictingDefinition)

        let twice = try Fixture.parse("include:\n  - one.yaml\n  - one.yaml\n", files: files)
        #expect(twice.file.services.keys.sorted() == ["shared"])
    }

    @Test("A file that includes itself, directly or not, is refused")
    func cycle() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse(
                "include:\n  - a.yaml\nservices:\n  web:\n    image: nginx\n",
                files: [
                    "/project/a.yaml": "include:\n  - b.yaml\nservices:\n  a:\n    image: nginx\n",
                    "/project/b.yaml": "include:\n  - a.yaml\nservices:\n  b:\n    image: nginx\n",
                ]
            )
        }
        #expect(error?.reason == .circularReference)
        #expect(error?.problem.contains("`a.yaml` includes `b.yaml` includes `a.yaml`") == true)
    }

    @Test("A missing included file is an error at the include")
    func missingFile() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse("include:\n  - nope.yaml\nservices:\n  web:\n    image: nginx\n")
        }
        #expect(error?.reason == .unreadableFile)
        #expect(error?.mark == SourceMark(line: 2, column: 5))
    }
}
