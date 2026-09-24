import ComposeModel
import ComposeParser
import Foundation
import Testing

@Suite("Rendering")
struct RenderingTests {
    @Test("The output read back as a compose file gives the same services")
    func roundTrip() throws {
        let original = try Fixture.parse(
            """
            services:
              app:
                build:
                  context: ./app
                  args: { V: "2" }
                  target: prod
                command: ["echo", "$$HOME", "yes", "1.5"]
                environment:
                  PW: "pa$$word"
                  ENABLED: "true"
                  PORT: "8080"
                  EMPTY: ""
                  TILDE: "~"
                ports:
                  - "127.0.0.1:8080:80/udp"
                  - "9000:9000"
                volumes:
                  - ./data:/data:ro
                  - /cache
                  - type: tmpfs
                    target: /scratch
                    read_only: true
                    tmpfs: { size: 64m }
                tmpfs: ["/run:size=8m,noexec"]
                entrypoint: []
                user: "1000:1000"
                dns: [1.1.1.1]
                dns_search: [example.com]
                dns_opt: [ndots:2]
                deploy:
                  resources:
                    limits: { cpus: "0.5", memory: 512M }
                depends_on: [db]
                x-note: { owner: me, count: 3 }
              db:
                image: postgres
                container_name: "null"
                working_dir: /var/lib
                labels:
                  tier: "on"
                networks: [back]
            networks:
              back:
                driver: bridge
                labels: { team: data }
            """
        )
        let yaml = try ComposeFileRenderer.yaml(for: original.file, projectName: "demo")
        let reread = try Fixture.parse(yaml)

        #expect(reread.file.name == "demo")
        // Mount order is not part of what a service means (the hash sorts them), and tmpfs
        // mounts come back from a key of their own.
        func normalised(_ services: [String: Service]) -> [String: Service] {
            services.mapValues { service in
                var service = service
                service.mounts.sort { $0.target < $1.target }
                return service
            }
        }
        var expected = original.file.services
        // Written down as the network compose would attach it to.
        expected["app"]?.networks = ["default"]
        #expect(normalised(reread.file.services) == normalised(expected))
        #expect(original.file.services["app"]?.mounts.count == 3)
        // The driver is reported on the way in and not honoured, so it is not written out.
        #expect(reread.file.networks["back"] == NetworkSpec(key: "back", name: "demo_back", labels: ["team": "data"]))
        #expect(reread.file.networks["default"] == NetworkSpec(key: "default", name: "demo_default"))
        #expect(reread.findings.isEmpty)
    }
}
