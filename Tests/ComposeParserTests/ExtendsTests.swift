import ComposeModel
import ComposeParser
import Foundation
import Testing

@Suite("extends")
struct ExtendsTests {
    @Test("A base in another file resolves its paths against its own directory")
    func baseFilePaths() throws {
        let result = try Fixture.parse(
            """
            services:
              app:
                extends:
                  file: .config/base.yaml
                  service: app
                build:
                  args:
                    VERSION: "2"
            """,
            files: [
                "/project/.config/base.yaml": """
                services:
                  app:
                    build:
                      context: .
                      args:
                        VERSION: "1"
                        MODE: dev
                    env_file: ./app.env
                    volumes:
                      - ../dist:/srv
                """,
                "/project/.config/app.env": "FROM_FILE=yes\n",
            ]
        )
        let app = try #require(result.file.services["app"])
        // The main file's `build:` has no context, and must not reset the base's.
        #expect(app.build == Service.Build(context: "/project/.config", args: ["VERSION": "2", "MODE": "dev"]))
        #expect(app.mounts == [Service.Mount(source: .bind("/project/dist"), target: "/srv")])
        #expect(app.environment == ["FROM_FILE": "yes"])
    }

    @Test("Mappings merge by key, lists append, a command is replaced, a mount is keyed by its target")
    func mergeRules() throws {
        let result = try Fixture.parse(
            """
            services:
              common:
                image: busybox
                command: ["echo", "base"]
                environment:
                  TZ: utc
                  PORT: "80"
                labels:
                  tier: base
                ports:
                  - "8080:80"
                volumes:
                  - ./data:/data
                  - ./logs:/logs
                dns: 1.1.1.1
                depends_on: [db]
              cli:
                extends: common
                command: ["echo", "cli"]
                environment:
                  PORT: "8080"
                ports:
                  - "8080:80"
                  - "9090:90"
                volumes:
                  - ./other:/data:ro
                dns: 8.8.8.8
                depends_on: [db, cache]
              db:
                image: postgres
              cache:
                image: redis
            """
        )
        let cli = try #require(result.file.services["cli"])
        #expect(cli.image == "busybox")
        #expect(cli.command == ["echo", "cli"])
        #expect(cli.environment == ["TZ": "utc", "PORT": "8080"])
        #expect(cli.labels == ["tier": "base"])
        #expect(cli.ports.map(\.description) == ["8080:80/tcp", "9090:90/tcp"])
        #expect(cli.mounts == [
            Service.Mount(source: .bind("/project/logs"), target: "/logs"),
            Service.Mount(source: .bind("/project/other"), target: "/data", readOnly: true),
        ])
        #expect(cli.dns == ["1.1.1.1", "8.8.8.8"])
        #expect(cli.dependsOn.map(\.service) == ["db", "cache"])
    }

    @Test("Inline environment beats env_file whichever level wrote either")
    func environmentAcrossLevels() throws {
        let result = try Fixture.parse(
            """
            services:
              base:
                image: nginx
                environment:
                  MODE: base-inline
              web:
                extends: base
                env_file: ./web.env
            """,
            files: ["/project/web.env": "MODE=from-file\nOTHER=file\n"]
        )
        #expect(result.file.services["web"]?.environment == ["MODE": "base-inline", "OTHER": "file"])
    }

    @Test("A chain is followed to the end, each level relative to the file it is in")
    func chain() throws {
        let result = try Fixture.parse(
            """
            services:
              web:
                extends: { file: a/one.yaml, service: one }
            """,
            files: [
                "/project/a/one.yaml": "services:\n  one:\n    extends: { file: b/two.yaml, service: two }\n    container_name: web-one\n",
                "/project/a/b/two.yaml": "services:\n  two:\n    image: nginx\n    container_name: two\n    working_dir: /two\n",
            ]
        )
        let web = try #require(result.file.services["web"])
        #expect(web.image == "nginx")
        #expect(web.containerName == "web-one")
        #expect(web.workingDirectory == "/two")
    }

    @Test("A chain that comes back on itself is refused and named")
    func cycle() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse(
                "services:\n  a:\n    extends: b\n  b:\n    extends: a\n    image: nginx\n"
            )
        }
        #expect(error?.reason == .circularReference)
        #expect(error?.problem.contains("`a` extends `b` extends `a`") == true)
    }

    @Test("A missing base file or service is an error at the extends")
    func missingBase() throws {
        let noFile = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  a:\n    extends: { file: base.yaml, service: a }\n")
        }
        #expect(noFile?.reason == .unreadableFile)
        #expect(noFile?.mark?.line == 3)

        let noService = #expect(throws: ParseError.self) {
            try Fixture.parse(
                "services:\n  a:\n    extends: { file: base.yaml, service: nope }\n",
                files: ["/project/base.yaml": "services:\n  a:\n    image: nginx\n"]
            )
        }
        #expect(noService?.reason == .undefinedReference)
        #expect(noService?.problem.contains("`base.yaml`") == true)
    }

    @Test("A finding in a base file names that file, and goes away when the service overrides the key")
    func baseFindings() throws {
        let files = ["/project/base.yaml": "services:\n  app:\n    image: nginx\n    restart: always\n    privileged: true\n"]
        let inherited = try Fixture.parse("services:\n  app:\n    extends: { file: base.yaml, service: app }\n", files: files)
        #expect(inherited.findings.map(\.key).sorted() == ["privileged", "restart"])
        let restart = try #require(inherited.findings.first { $0.key == "restart" })
        #expect(restart.mark == SourceMark(line: 4, column: 14, file: "base.yaml"))
        #expect(restart.message.hasPrefix("base.yaml:4:14: "))

        let overridden = try Fixture.parse(
            "services:\n  app:\n    extends: { file: base.yaml, service: app }\n    restart: \"no\"\n",
            files: files
        )
        #expect(overridden.findings.map(\.key) == ["privileged"])
    }
}
