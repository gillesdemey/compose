import ComposeModel
import ComposeParser
import Foundation
import Testing

@Suite("healthcheck and depends_on conditions")
struct HealthAndDependencyTests {
    @Test("Every form of test becomes the argument vector that is run, with compose's defaults")
    func testForms() throws {
        let result = try Fixture.parse(
            """
            services:
              exec:
                image: a
                healthcheck: { test: ["CMD", "pg_isready", "-q"] }
              shell:
                image: a
                healthcheck: { test: ["CMD-SHELL", "curl -f localhost || exit 1"], interval: 1m30s, timeout: 500ms, retries: 5, start_period: 10s, start_interval: 2s }
              bare:
                image: a
                healthcheck: { test: "wget -q -O- localhost" }
              none:
                image: a
                healthcheck: { test: ["NONE"] }
              off:
                image: a
                healthcheck: { test: ["CMD", "true"], disable: true }
            """
        )
        let services = result.file.services
        #expect(services["exec"]?.healthcheck == Service.Healthcheck(test: ["pg_isready", "-q"]))
        #expect(services["exec"]?.healthcheck?.interval == 30)
        #expect(services["shell"]?.healthcheck == Service.Healthcheck(
            test: ["/bin/sh", "-c", "curl -f localhost || exit 1"],
            interval: 90,
            timeout: 0.5,
            retries: 5,
            startPeriod: 10,
            startInterval: 2
        ))
        #expect(services["bare"]?.healthcheck?.test == ["/bin/sh", "-c", "wget -q -O- localhost"])
        #expect(services["none"]?.healthcheck == nil)
        #expect(services["off"]?.healthcheck == nil)
        #expect(result.findings.isEmpty)
    }

    @Test("A test or duration compose would reject is refused at its line")
    func badValues() throws {
        let test = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  a:\n    image: a\n    healthcheck: { test: [\"curl\", \"localhost\"] }\n")
        }
        #expect(test?.reason == .invalidValue)
        #expect(test?.mark?.line == 4)

        let duration = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  a:\n    image: a\n    healthcheck: { test: [CMD, \"true\"], interval: 30 }\n")
        }
        #expect(duration?.reason == .invalidValue)
        #expect(duration?.problem.contains("`30` is not a duration") == true)
    }

    @Test("Conditions are read, and one compose does not know is refused")
    func conditions() throws {
        let result = try Fixture.parse(
            """
            services:
              db: { image: a, healthcheck: { test: [CMD, "true"] } }
              init: { image: a }
              app:
                image: a
                depends_on:
                  db: { condition: service_healthy }
                  init: { condition: service_completed_successfully }
              web: { image: a, depends_on: [app] }
            """
        )
        #expect(result.file.services["app"]?.dependsOn == [
            Service.Dependency("db", condition: .healthy),
            Service.Dependency("init", condition: .completedSuccessfully),
        ])
        #expect(result.file.services["web"]?.dependsOn == [Service.Dependency("app")])
        #expect(result.findings.isEmpty)

        let unknown = #expect(throws: ParseError.self) {
            try Fixture.parse("services:\n  db: { image: a }\n  app:\n    image: a\n    depends_on:\n      db: { condition: service_ready }\n")
        }
        #expect(unknown?.reason == .invalidValue)
        #expect(unknown?.mark?.line == 6)
    }

    @Test("Waiting for health on a service with no healthcheck blocks, because there is nothing to probe")
    func healthyWithoutHealthcheck() throws {
        let result = try Fixture.parse(
            """
            services:
              db: { image: postgres }
              app:
                image: a
                depends_on: { db: { condition: service_healthy } }
            """
        )
        let finding = try #require(result.blockingFindings.first)
        #expect(result.blockingFindings.count == 1)
        #expect(finding.key == "depends_on")
        #expect(finding.service == "app")
        #expect(finding.message.contains("`db`"))
    }

    @Test("Through extends, a healthcheck merges field by field and a condition is overridden by name")
    func extendsMerges() throws {
        let result = try Fixture.parse(
            """
            services:
              base:
                image: a
                entrypoint: ["/entry.sh"]
                user: "1000"
                healthcheck: { test: [CMD, check], interval: 5s, retries: 5 }
                depends_on:
                  db: { condition: service_started }
                  cache: { condition: service_healthy }
              app:
                extends: base
                entrypoint: null
                healthcheck: { interval: 1s }
                depends_on:
                  db: { condition: service_healthy }
              cleared:
                extends: base
                entrypoint: []
              db: { image: a, healthcheck: { test: [CMD, "true"] } }
              cache: { image: a, healthcheck: { test: [CMD, "true"] } }
            """
        )
        let app = try #require(result.file.services["app"])
        #expect(app.healthcheck == Service.Healthcheck(test: ["check"], interval: 1, retries: 5))
        #expect(app.dependsOn == [
            Service.Dependency("db", condition: .healthy),
            Service.Dependency("cache", condition: .healthy),
        ])
        // `null` does not override, and an empty list does.
        #expect(app.entrypoint == ["/entry.sh"])
        #expect(result.file.services["cleared"]?.entrypoint == [])
        #expect(app.user == "1000")
    }
}
