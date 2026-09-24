import ComposeModel
import ComposeParser
import Foundation
import Testing

@Suite("Parsing a whole file")
struct FileParsingTests {
    @Test("A realistic file resolves into the model")
    func fullFixture() throws {
        let result = try Fixture.parse(try Fixture.text("full"))
        let file = result.file

        #expect(file.name == "shop")
        #expect(file.services.count == 3)
        #expect(file.orderedServices.map(\.name) == ["api", "db", "web"])

        let db = try #require(file.services["db"])
        #expect(db.image == "postgres:16")
        #expect(db.environment["POSTGRES_PASSWORD"] == "secret")
        #expect(db.environment["POSTGRES_DB"] == "shop")
        #expect(db.mounts == [
            Service.Mount(source: .bind("/project/data"), target: "/var/lib/postgresql/data")
        ])
        #expect(db.resources?.cpus == 2)
        #expect(db.resources?.memoryBytes == 1 << 30)

        let api = try #require(file.services["api"])
        #expect(api.build?.context == "/project/api")
        #expect(api.build?.dockerfile == "Dockerfile.dev")
        #expect(api.build?.args == ["VERSION": "1.2"])
        #expect(api.command == ["./serve", "--port", "8080"])
        #expect(api.workingDirectory == "/srv")
        #expect(api.environment == ["DATABASE_URL": "postgres://db:5432/shop"])
        #expect(api.labels == ["com.example.role": "api"])
        #expect(api.dependsOn.map(\.service) == ["db"])
        #expect(api.ports == [
            Service.Port(hostPort: 8080, containerPort: 8080),
            Service.Port(hostIP: "127.0.0.1", hostPort: 9229, containerPort: 9229),
        ])
        // Nameservers keep the order they were written in, because that is a preference order.
        #expect(api.dns == ["1.1.1.1", "8.8.8.8"])
        // The short form is a bare string, and means a list of one.
        #expect(api.dnsSearch == ["example.internal"])
        #expect(api.dnsOptions == ["ndots:1"])
        #expect(db.dns.isEmpty)

        let web = try #require(file.services["web"])
        #expect(web.containerName == "shop-front")
        #expect(web.mounts.first?.readOnly == true)
        #expect(file.networks["backend"]?.resolvedName(projectName: "shop") == "shop_backend")

        // Nothing in this file is beyond v1, so nothing should be reported.
        #expect(result.findings.isEmpty)
        #expect(result.interpolationWarnings.isEmpty)
    }

    @Test("Version 2 files are refused rather than half read")
    func versionTwoIsRefused() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse(try Fixture.text("version-2"))
        }
        #expect(error?.reason == .unsupportedSpecVersion)
        #expect(error?.mark?.line == 1)
    }

    @Test("An empty or shapeless file is an error, not an empty project")
    func shapelessFiles() throws {
        #expect(throws: ParseError.self) { try Fixture.parse("") }
        #expect(throws: ParseError.self) { try Fixture.parse("- one\n- two\n") }
        let missing = #expect(throws: ParseError.self) { try Fixture.parse("name: thing\n") }
        #expect(missing?.reason == .missingKey)
    }

    @Test("Malformed YAML keeps the line it failed on")
    func malformedYAML() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  web:\n   image: \"unclosed\n")
        }
        #expect(error?.reason == .malformedYAML)
        #expect(error?.mark != nil)
    }

    @Test("A service needs something to run")
    func serviceWithoutImageOrBuild() throws {
        let error = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  web:\n    command: sleep 1\n")
        }
        #expect(error?.reason == .missingKey)
    }

    @Test("References that go nowhere are refused")
    func danglingReferences() throws {
        let dependency = #expect(throws: ParseError.self) {
            try Fixture.parse(
                """
                services:
                  web:
                    image: nginx
                    depends_on: [db]
                """
            )
        }
        #expect(dependency?.reason == .undefinedReference)

        let network = #expect(throws: ParseError.self) {
            try Fixture.parse(
                """
                services:
                  web:
                    image: nginx
                    networks: [backend]
                """
            )
        }
        #expect(network?.reason == .undefinedReference)
    }
}

@Suite("What a file asks for and will not get")
struct FindingTests {
    @Test("Unsupported keys are reported with their severity, service and line")
    func unsupportedKeys() throws {
        let result = try Fixture.parse(try Fixture.text("unsupported"))
        let byKey = Dictionary(grouping: result.findings, by: \.key)

        let restart = try #require(byKey["restart"]?.first)
        #expect(restart.service == "app")
        #expect(restart.severity == .behavioural)
        // The reason names the policy asked for, since `no` is honoured and the rest are not.
        #expect(restart.support.reason?.contains("`always`") == true)
        #expect(restart.mark?.line == 4)
        #expect(restart.message.contains("`restart` in service `app`"))

        #expect(byKey["cap_add"]?.first?.severity == .behavioural)
        #expect(byKey["profiles"]?.first?.support.severity == .behavioural)
        #expect(byKey["ulimits"] != nil)
        #expect(byKey["privileged"] != nil)

        // Cosmetic keys are reported too, and do not block.
        let platform = try #require(byKey["platform"]?.first)
        #expect(platform.severity == .cosmetic)
        #expect(!result.blockingFindings.contains(platform))

        // A key nobody has ever defined is reported as a typo rather than as unsupported.
        let unknown = try #require(byKey["typo_key"]?.first)
        #expect(unknown.kind == .unknownKey)

        // The file still parses: findings are not errors.
        #expect(result.file.services["app"]?.image == "app:latest")
        #expect(result.file.services["app"]?.labels == ["role": "app"])
    }

    @Test("A port with no host port is published by nobody, and says so")
    func ephemeralPort() throws {
        let result = try Fixture.parse(try Fixture.text("unsupported"))
        let port = try #require(result.file.services["app"]?.ports.first)
        #expect(port.hostPort == nil)
        #expect(port.containerPort == 3000)
        let finding = try #require(result.findings.first { $0.key == "ports" })
        #expect(finding.kind == .unhandledForm)
        #expect(finding.severity == .behavioural)
    }

    @Test("A named volume is dropped loudly rather than mounted quietly")
    func namedVolume() throws {
        let result = try Fixture.parse(try Fixture.text("unsupported"))
        #expect(result.file.services["app"]?.mounts.isEmpty == true)
        let finding = try #require(result.findings.first { $0.key == "volumes" })
        #expect(finding.severity == .behavioural)
        #expect(finding.message.contains("appdata"))
    }

    @Test("A finding says whether the runtime is the obstacle, or this project is")
    func obstacleIsNamed() throws {
        let result = try Fixture.parse(
            """
            services:
              app:
                image: nginx
                restart: always
                profiles: [debug]
                nonsense: 1
            """
        )
        let byKey = Dictionary(grouping: result.findings, by: \.key)

        // The runtime has no restart policy: no work here changes that.
        let restart = try #require(byKey["restart"]?.first)
        #expect(restart.support.needsRuntimeSupport)
        #expect(!restart.support.isDeferred)

        // Selecting profiles is only a matter of this not doing it yet.
        let profiles = try #require(byKey["profiles"]?.first)
        #expect(profiles.support.isDeferred)
        #expect(!profiles.support.needsRuntimeSupport)

        // And a key nobody defines is neither.
        #expect(byKey["nonsense"]?.first?.kind == .unknownKey)
    }

    @Test("A key named to ignore covers the keys under it, and nothing that only starts the same")
    func ignoredKeyMatching() throws {
        let result = try Fixture.parse(
            """
            services:
              app:
                image: nginx
                restart: always
                volumes:
                  - type: npipe
                    target: /pipe
                devices: ["/dev/fuse"]
            """
        )
        let byKey = Dictionary(grouping: result.findings, by: \.key)
        let tmpfsLike = try #require(byKey["volumes.type"]?.first)
        #expect(tmpfsLike.isAbout(key: "volumes"))
        #expect(tmpfsLike.isAbout(key: "volumes.type"))
        #expect(!tmpfsLike.isAbout(key: "volumes.ty"))
        let restart = try #require(byKey["restart"]?.first)
        #expect(restart.isAbout(key: "restart"))
        #expect(!restart.isAbout(key: "rest"))
        #expect(!restart.isAbout(key: "restart.policy"))
        #expect(byKey["devices"]?.first?.isAbout(key: "restart") == false)
    }

    @Test("`restart: no` is honoured exactly, so it is not reported")
    func restartNoIsHonoured() throws {
        let honoured = try Fixture.parse(
            """
            services:
              a:
                image: nginx
                restart: no
              b:
                image: nginx
                restart: "no"
            """
        )
        #expect(honoured.findings.isEmpty)

        let refused = try Fixture.parse(
            """
            services:
              a:
                image: nginx
                restart: always
              b:
                image: nginx
                restart: unless-stopped
            """
        )
        #expect(refused.blockingFindings.count == 2)
        #expect(refused.findings.allSatisfy { $0.key == "restart" })
        #expect(refused.findings.first?.message.contains("`always`") == true)
    }

    @Test("A real compose key this does not honour is not reported as a typo")
    func knownKeysAreNotTypos() throws {
        // `pull_policy` is a key the spec defines and this does not act on. Calling that a
        // typo would send someone looking for a spelling mistake that is not there.
        let result = try Fixture.parse(
            """
            services:
              web:
                image: nginx
                pull_policy: never
                not_a_key: 1
            """
        )
        let pullPolicy = try #require(result.findings.first { $0.key == "pull_policy" })
        #expect(pullPolicy.kind == .unhandledKey)
        #expect(pullPolicy.severity == .cosmetic)
        #expect(result.findings.first { $0.key == "not_a_key" }?.kind == .unknownKey)
    }

    @Test("`version` is obsolete, not fatal, and does not block")
    func obsoleteVersionKey() throws {
        let result = try Fixture.parse(
            """
            version: "3.8"
            services:
              web:
                image: nginx
            """
        )
        let finding = try #require(result.findings.first { $0.key == "version" })
        #expect(finding.severity == .cosmetic)
        #expect(result.blockingFindings.isEmpty)
    }
}
