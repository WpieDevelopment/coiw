# coiw - COI Wrapper for Code on Incus

A directory-aware CLI wrapper for [Code on Incus](https://github.com/mensfeld/code-on-incus). Each project directory gets its own persistent container - `coiw start` in `~/dev/project-a` will never touch the container for `~/dev/project-b`.

## Quick Install

```bash
curl -fsSL https://raw.githubusercontent.com/wpie/coiw/main/install.sh | bash
```

This installs both `coiw` (the wrapper) and `coi` (Code on Incus) to `/usr/local/bin`.

To install a specific version:

```bash
curl -fsSL https://raw.githubusercontent.com/wpie/coiw/main/install.sh | VERSION=v2.1.0 bash
```

## Prerequisites

- Ubuntu 24.04 LTS
- Incus installed and initialized
- User in `incus-admin` group
- ZFS storage pool configured
- COI image built (`coi build` from the [code-on-incus](https://github.com/mensfeld/code-on-incus) repo)

The install script can set up the full environment for you — see `SKIP_INCUS=0` and other options in `install.sh`.

## Commands

```
coiw start             Start or attach to persistent container for current directory
coiw stop              Stop the container (preserves it for later)
coiw rm                Delete the container permanently
coiw kill              Force kill and delete immediately

coiw code [args]       Launch Claude Code directly in the running container
coiw exec <cmd>        Run any command in the running container
coiw shell             Open a bash shell in the running container

coiw list              List all active COI containers
coiw stats             Live container resource monitoring
coiw stats --once      Single snapshot
coiw stats --json      Stream as NDJSON
coiw stats --json --once  Single JSON snapshot

coiw health            COI system health check
coiw clean             Clean up all stopped containers
coiw build             Build COI image (run from code-on-incus repo root)
coiw update            Update coiw and coi to the latest release

coiw version           Show version
coiw help              Show help

coiw <anything>        Passed through to coi directly
```

## Example Workflow

```bash
cd ~/dev/project-a
coiw start               # Creates a new persistent container

# ... Claude Code session, exit when done ...

cd ~/dev/project-b
coiw start               # Creates a SEPARATE container for project B

coiw stats --once        # Check resource usage

cd ~/dev/project-a
coiw start               # Attaches to the EXISTING container

coiw stop                # Done for the day
```

## How It Works

1. `coiw start` runs `coi list` and parses the output to find a persistent container whose workspace matches `$(pwd)`
2. If found and running: attaches to it (`coi attach`)
3. If found and stopped: resumes it (`coi shell --persistent --resume`)
4. If not found: creates a new one (`coi shell --persistent`)
5. Any unrecognized command is passed through to `coi` directly

## License

MIT
