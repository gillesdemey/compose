# Compose (for Apple Containers)

Container compose is a plugin for [apple/container](https://github.com/apple/container) that
brings Docker Compose ergonomics to Apple's container runtime.

Unlike earlier community efforts, which tend to be standalone binaries, this is an actual
_plugin_, installed into the `container` CLI, so the commands are:

```
container compose up
container compose down
```

It runs standalone on the CLI, and the same package backs the Compose tab in the
[Orchard](https://github.com/andrew-waters/orchard) app for containers, so a project brought
up in the terminal and one brought up in the app are the same project.

I would also encourage the community to rally around a single solution, contribute to it to
bring it up to spec with all features missing from Docker and for other UIs to build on so
that efforts are centralised and consistent rather than a fragmented ecosystem.

## Why this exists

Apple has explicitly ruled compose out of `container` upstream. The long-running compose
pull request ([apple/container#239](https://github.com/apple/container/pull/239)) was closed
in April 2026 by a maintainer, with the reasoning that Docker Compose is a free-standing
project whose source is not mingled with the Docker engine or CLI, and that container's
maintainers are focused on core functionality and on supporting plugins for ecosystem
integration.

So compose on this stack has to be built from scratch, outside the project, by someone who
wants it. That is what this is.

## How it fits together

Three pieces, sharing one implementation:

- **A Swift package.** The compose model, YAML parsing, a dependency graph, and a planner
  that turns a compose file plus the current state of the world into an ordered list of
  operations. Pure logic: no subprocesses, no XPC, testable without a running daemon.
- **A `container compose` plugin.** A thin binary over that package, installed into
  container's plugin directory, so `container compose up` works from the terminal.
- **A Compose tab in [Orchard](https://github.com/andrew-waters/orchard).** Orchard links
  this package over SwiftPM and executes plans over the same XPC path it already uses to
  create containers and networks, so the GUI never shells out and does not need the plugin
  installed at all.

The planner being a pure function is the reason for this shape. Ordering and reconciliation
are where compose tools get subtly wrong, and both are testable here without starting a
single container.

## Scope

The dividing line is what container's own create surface can already express.

**Supported:** `image`, `build`, `container_name`, `command`, `environment`, `env_file`,
`working_dir`, `ports`, bind `volumes`, `labels`, `networks`, `dns`, `dns_search`,
`dns_opt`, `deploy.resources`, and `depends_on` in its list form.

**Not yet:** `entrypoint`, named `volumes`, attaching to multiple networks, `profiles`,
`include`, `healthcheck`, and `depends_on` with conditions. `pull_policy` and `platform` are
read but not honoured: an image is pulled when it is missing, and everything on this stack is
linux/arm64.

**Not possible today:** `restart`, `user`, `cap_add`, `devices`, `tmpfs`, `ulimits`,
`secrets`, `configs`, `extra_hosts`, `privileged`, `network_mode`. These need runtime support
container does not have. Restart policy is tracked upstream at
[#2142](https://github.com/apple/container/issues/2142), health at
[#1502](https://github.com/apple/container/issues/1502).

Unsupported keys are never silently ignored. Quietly dropping `restart: always` would leave
someone believing their database comes back after a crash. The plugin refuses a file it
cannot honour, naming the key, the service and the line. Orchard lists what it would ignore,
lets you decide, and keeps showing it on the project afterwards.

Two limitations worth stating up front. Without health reporting in the runtime, `up` starts
dependencies before dependents but does not wait for them to become ready. And a service
does not answer to its service name: hostnames have to be unique across every container on
the machine, so a container is reachable as `<project>-<service>` rather than as `db`.
Compose's own naming needs per-network namespacing, which is
[apple/container#1809](https://github.com/apple/container/issues/1809).

## Using it

Every release ships the plugin directory built and packaged exactly as it is installed, so
unpacking it into container's plugin directory is the whole install:

```
tar -xzf compose-<version>-macos-arm64.tar.gz
sudo mkdir -p /usr/local/libexec/container-plugins
sudo cp -R compose /usr/local/libexec/container-plugins/
```

Or build it yourself:

```
make build
sudo make install
```

The plugin directory is root owned, which is what the `sudo` is for. The container installer
wipes that directory on every upgrade
([apple/container#1617](https://github.com/apple/container/issues/1617)), so expect to
install again after updating container.

Then, in a directory with a `compose.yaml`:

```
container compose up                 # create and start everything, in dependency order
container compose up --dry-run       # work out the plan, print it, change nothing
container compose down               # stop and remove it all again
container compose config             # print the project as it will be run
```

`up`, `down` and `config`, matching compose. There are no other verbs yet: container's own
`ls`, `logs` and `exec` cover the rest meanwhile.

Every verb takes `-f` to point at a file elsewhere and `-p` to name the project (it otherwise
comes from the file's `name`, then from the directory). `up` and `down` take `--dry-run`. `up`
also takes `--force-recreate`, `--pull missing|always|never` and `--keep-orphans`; `down` takes
`--keep-networks`; `config` takes `--services` to print only the service names.

`config` prints the project the way `docker compose config` does, as a compose file with
variables substituted, `env_file` merged in, paths absolute, short forms expanded and the
default network written out. It prints what this will act on, which is not always everything
the file asked for: a key it cannot honour is missing from the output and listed on stderr
instead, and `config` never refuses. Its output reads back as a compose file, to this and to
compose.

Running `up` twice is the interesting case. The second run compares each service against the
hash stamped on the container it produced, and creates, starts, leaves alone, recreates or
removes each one accordingly. Containers are the only record: there is no state file.

### What it refuses

The plugin will not run a file it cannot honour. It names the key, the service and the line,
and creates nothing:

```
error: compose.yaml asks for 2 things this cannot do
  8:14: `restart` in service `db` is not honoured: container has no restart policy; a
        container that exits stays exited
  15:11: `user` in service `api` is not honoured: the create surface cannot set the process user
error: nothing was created.
```

Keys that cost nothing to ignore, such as an obsolete `version`, are printed as notes and
stepped over. The difference is a severity carried per key, not a judgement made at the
point of refusal.

## Using it from Orchard

[Orchard](https://github.com/andrew-waters/orchard) is a native macOS app for managing
containers, machines and local AI models on `apple/container`, and its Compose tab is built
on this package:

```
brew install orchard
```

It reads a compose file, shows what it found and what it would ignore before anything runs,
and then executes the same plans this plugin does. The plugin does not have to be installed
for that. Source and releases are at
[andrew-waters/orchard](https://github.com/andrew-waters/orchard).

## Building

```
swift build
swift test
```

Three library targets, none of which executes anything:

- `ComposeModel`, the spec types, plus the table of which compose keys are honoured,
  deferred or impossible, with a severity on each.
- `ComposeParser`, YAML to model: interpolation, `.env` and `env_file`, short and long
  forms, and a line and column on every error.
- `ComposePlanner`, the dependency graph, project identity and hashing, and the planner
  itself, which takes a parsed file and a snapshot of what exists and returns an ordered
  list of operations.

Plus one executable target, `compose`, which is the plugin: it parses, plans, prints, and
executes the plan. It is the only target that knows a runtime exists.

[Yams](https://github.com/jpsim/Yams) is the libraries' only dependency, and deliberately
so. It is the YAML parser `apple/container` already uses, so linking this package adds
nothing to the dependency graph. It also reports a line and column for every node, which is
what lets a refusal name the line it is refusing.

The plugin adds `apple/container` itself and `swift-argument-parser`, both kept inside the
executable target: a package that makes plans has no business linking a client for the thing
that carries them out. One operation, `build`, is not carried out in process. Starting the
BuildKit builder, dialling it and unpacking the result are all things the `container` CLI
already does, so the plugin shells out to `container build` rather than reimplementing the
hard part. Orchard does the same for the same reason.

## Requirements

- Apple silicon Mac running macOS 26
- [apple/container](https://github.com/apple/container) 1.4.1 or later

## Licence

MIT.
