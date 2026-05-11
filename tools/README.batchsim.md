# BatchRogueSimulator on the HEAP cluster

Pipeline for generating large batches of `forge.tools.BatchRogueSimulator`
games by fanning out across the Recurse HEAP hosts (broome, crosby, mercer,
greene). Each script takes `--help` for its full flag list; this README is the
roadmap.

## Pieces

| Script | Where it runs | Job |
| --- | --- | --- |
| `ship_batchsim.sh` | local dev box | build classpath bundle, scp + extract to each host |
| `run_batch_simulator.sh` | anywhere with mvn | one-shot run, builds on demand |
| `run_batch_simulator_prebuilt.sh` | remote hosts | one-shot run from prebuilt artifacts (no mvn) |
| `run_remote_fanout.sh` | local dev box | launch / check / stop N procs × M hosts via ssh |
| `collect_remote_games.sh` | local dev box | merge `batches/` from every host onto a collector and zip |

## One-shot local run (smoke test)

```
tools/run_batch_simulator.sh --count 5 --output-dir /tmp/smoke --seed 0
```

First run does `mvn flatten:flatten install` for parent + sibling modules,
`test-compile` for forge-gui-desktop, and caches the dependency classpath. Re-
runs reuse the cache. Override heap with `BATCH_SIM_XMX=4096m`.

## Deploy to the cluster

```
tools/ship_batchsim.sh                                 # all 4 default hosts
tools/ship_batchsim.sh --hosts btp@broome.cluster.recurse.com
tools/ship_batchsim.sh --no-build                      # reuse local target/ trees
tools/ship_batchsim.sh --no-deploy                     # just produce forge-batchsim.tar.gz
```

Build step runs `mvn -pl forge-gui-desktop -am -U test-compile
dependency:copy-dependencies` (`-am` is required so `${revision}` resolves and
flatten produces correct POMs). Tarball is ~120MB; remote layout is
`~/forge/` by default (override with `--remote-dir`). Deploy parallelizes
across hosts; per-host logs are streamed back at the end.

First-time ssh to a host needs key-based auth and a known_hosts entry. The
deploy step uses `BatchMode=yes` so it will not prompt — verify connectivity
once with `ssh -o BatchMode=yes <host> hostname` if it fails.

## Launch the fan-out

```
tools/run_remote_fanout.sh                             # 4 hosts × 4 procs × 10000 games = 160k
tools/run_remote_fanout.sh --procs 6 --count 5000
tools/run_remote_fanout.sh --hosts btp@broome.cluster.recurse.com,btp@crosby.cluster.recurse.com
tools/run_remote_fanout.sh --seed-base 100              # skip already-used seed range
```

Seeds are assigned disjointly across all (host, proc) pairs, so output
directories (`batches/run-<seed>/`) never collide. Each remote process is
started with `nohup ... &` so the launcher ssh sessions can disconnect.

Default 4 procs/host fits comfortably in the cluster's RAM headroom; bumping
past 6 risks OOM-kill at the default 2g heap.

## Monitor

```
tools/run_remote_fanout.sh --check
```

Per host: count of running `BatchRogueSimulator` processes plus the last
progress line from each `batches/run-<seed>.log`. Run repeatedly to watch
progress.

Ad-hoc deeper poking:
```
ssh btp@broome.cluster.recurse.com 'tail -f ~/forge/batches/run-1.log'
ssh btp@broome.cluster.recurse.com 'ls ~/forge/batches/run-1 | wc -l'   # games done
```

## Stop

```
tools/run_remote_fanout.sh --stop                       # pkill BatchRogueSimulator everywhere
tools/run_remote_fanout.sh --stop --hosts btp@broome.cluster.recurse.com
```

## Collect output

```
tools/collect_remote_games.sh                           # → broome, zipped
tools/collect_remote_games.sh --collector btp@crosby.cluster.recurse.com
tools/collect_remote_games.sh --output forge-games.zip
tools/collect_remote_games.sh --no-zip                  # leave merged batches/ unzipped on collector
```

Non-collector hosts stream their `batches/` directly to the collector over
ssh (agent-forwarded from local — make sure `ssh-add -l` lists keys for every
host). Safe to run while the simulator is still going; in-flight files may
end up truncated and should be filtered downstream.

## Typical session

```
tools/ship_batchsim.sh                                  # deploy
tools/run_remote_fanout.sh --procs 4 --count 10000      # launch 160k games
tools/run_remote_fanout.sh --check                      # ...minutes later
tools/collect_remote_games.sh -o games-$(date +%F).zip  # pull results to broome
scp btp@broome.cluster.recurse.com:games-*.zip .        # down to local
```
