# Meshtastic (lane E) — Hardware Verification Checklist and Results

Spec: `docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md` §1 criterion 3, §7 lane E
item 4, §9. Performed by the user with two physical Meshtastic radios; nothing here is automated.
Every shell line below is ONE command. Task 15 runs this from the ReTiCA MAIN checkout after
Part 1 is merged (the paths below point there).

## Equipment (fill in first)

| | Radio A (iPhone side) | Radio B (Mac / second iPhone side) |
|---|---|---|
| model | | |
| firmware version (`meshtastic --port <port> --info`, or the Meshtastic app) | | |
| region | | |
| modem preset (name and raw value, e.g. ShortFast 6) | | |
| original preset of radio B (before this run rewrites it; restore at the end) | n/a | |
| LoRa hop limit | | |
| primary channel name and PSK identical on both? | | |

| | value |
|---|---|
| iPhone model(s), iOS version(s) | |
| ReTiCAMsgr build (app `main` commit) | |
| ReTiCA `main` commit | |
| Mac `meshtastic` python package version (`conda run -n rns python -m pip show meshtastic`) | |

Both radios: same region, same preset, same primary channel (index 0, same name and PSK).
Prefer ShortTurbo or ShortFast (spec §1 "Expectation setting").

## Mac setup (once)

1. `conda run -n rns python -m pip install meshtastic`
2. `mkdir -p ~/.reticulum/interfaces`
3. `cp /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCAInterfacesTests/Vectors/landandair_Meshtastic_Interface.py ~/.reticulum/interfaces/Meshtastic_Interface.py`
4. `shasum -a 256 ~/.reticulum/interfaces/Meshtastic_Interface.py` → must print
   `8b71aa8efc7624dba05202c5eb356a10a48c31bee783cd4c9295038370b394ab` (landandair commit
   e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a, unmodified).
5. Plug radio B into the Mac by USB. `ls /dev/cu.*` → note its port (e.g. `/dev/cu.usbserial-0001`
   or `/dev/cu.usbmodem…`). USB, not BLE: the Mac's Bluetooth should stay out of the experiment.
6. If `~/.reticulum/config` exists: `cp ~/.reticulum/config ~/.reticulum/config.pre-meshtastic`.
   Add this stanza under `[interfaces]` (the file name above makes `type = Meshtastic_Interface`
   load it; keys parsed in `__init__`, L91-95 of the pinned file):

   **WARNING: `data_speed` omitted = 8 (ShortTurbo), so the radio is rewritten anyway. Set it
   explicitly. This changes radio B's saved config and reboots it. Note B's original preset in the
   Equipment table (row "original preset of radio B") so you can restore it afterward (last step of
   this checklist).**

   ```
     [[Meshtastic Interface]]
       type = Meshtastic_Interface
       enabled = true
       port = /dev/cu.usbserial-0001
       data_speed = 6
       hop_limit = 1
   ```
   `port` is radio B's serial port (alternatives: `ble_port = <radio name or address>`,
   `tcp_port = <host[:port]>` for a WiFi radio — set exactly one). `data_speed` MUST be radio A's
   preset raw value (8 ShortTurbo, 6 ShortFast, 5 ShortSlow, 4 MediumFast, 3 MediumSlow,
   0 LongFast, 7 LongModerate, 1 LongSlow): landandair REWRITES radio B's preset to it on connect
   (`configure_device`, L174-178; the radio reboots once and the interface reconnects after ~10 s)
   and paces by it.
   `hop_limit = 1` matches ReTiCA's fixed hop limit. No IFAC: ReTiCAMsgr v1 has no Meshtastic
   IFAC setting.
7. Start rnsd in its own terminal: `/Users/ell/opt/anaconda3/envs/rns/bin/rnsd -v`
8. In another terminal: `/Users/ell/opt/anaconda3/envs/rns/bin/rnstatus` → `MeshtasticInterface[Meshtastic Interface]` is `Up`.
9. Start the probe in a third terminal:
   `/Users/ell/opt/anaconda3/envs/rns/bin/python -u /Users/ell/development/ios/pods/ReTiCA/Scripts/meshtastic-hardware/lxmf_probe.py --name "Mac probe"`
   → prints `LXMF address: <hex>`. Record it.

## iPhone setup

- [ ] Radio A is NOT connected to the Meshtastic app or Meshtastified (one BLE client per radio).
- [ ] ReTiCAMsgr → Settings → Meshtastic: toggle on, Choose radio… → pick radio A, then Connect.
- [ ] Diagnostics → Meshtastic: status `online`, preset = radio A's, node `!xxxxxxxx`, no adapter row.

## (a) iPhone → radio A → air → radio B → Mac rnsd + landandair, and back

- [ ] The Mac probe prints `ANNOUNCE <iPhone address> name=<your display name>` (the iPhone's
      interface-up announce, targeted at the radio). Record seconds from Connect to the line.
- [ ] In ReTiCAMsgr the "Mac probe" appears in the announce list (tap Announce on the iPhone if
      needed; announces cross the radio slowly).
- [ ] iPhone → Mac: send "hello mac" to Mac probe. The probe prints `RECEIVED … content='hello mac'`
      with `signature_validated=True`. Record seconds from tap to line, and `method`.
- [ ] Mac → iPhone: stop the probe (Ctrl-C) and rerun it with
      `--send <iPhone address> --text "hello iphone"` → `DELIVERED after N s`; the message shows on
      the iPhone. Record N.
- [ ] Long message (≈1 000 characters) iPhone → Mac: it either arrives (slow, link/resource) or the
      iPhone marks it failed cleanly. No crash, no wedge; record which and how long.
- [ ] Diagnostics counters after the run: reassembled, malformed, evicted, timed out, oversize,
      queue full, send failed.

## (b) iPhone ↔ iPhone

Two iPhones, each paired with its own radio (A and B; unplug B from the Mac, stop rnsd).
- [ ] Each sees the other's announce. Messages both ways arrive; record latency each way.
- [ ] With the receiving app backgrounded: a message still arrives or arrives on foreground; no
      crash (spec §9 background risk).
- [ ] Walk one radio out of range and back: Diagnostics shows offline then online without
      touching the app.

## (c) radio → ReTiCA gateway → TCP responder

Topology: Mac probe (instance 1, radio B via rnsd) —air— radio A —BLE— iPhone gateway (ReTiCAMsgr,
Meshtastic on, Relay on, TCP node = Mac hub) —TCP— Mac hub (instance 2) —TCP— responder = ReTiCAMsgr
in an iOS Simulator (node 127.0.0.1:4242). The responder is a ReTiCA node reached over TCP, so its
link responder timeout is the fixed 15 s (spec Contract 4 choice, unverified) while the initiator
sits behind the slow radio.
1. `mkdir -p /tmp/ReTiCA-hw/tcp-hub`
2. Write `/tmp/ReTiCA-hw/tcp-hub/config`:
   ```
   [reticulum]
     enable_transport = True
     share_instance = No

   [interfaces]
     [[TCP Hub]]
       type = TCPServerInterface
       enabled = true
       listen_ip = 0.0.0.0
       listen_port = 4242
   ```
   This hub is unauthenticated: bind `listen_ip` to your LAN IP instead of `0.0.0.0` if you can,
   and stop the hub and delete `/tmp/ReTiCA-hw/` after the test.
3. `/Users/ell/opt/anaconda3/envs/rns/bin/rnsd --config /tmp/ReTiCA-hw/tcp-hub -v`
4. Simulator ReTiCAMsgr: node 127.0.0.1:4242, Connect, note its LXMF address.
5. Gateway iPhone: node `<Mac LAN IP>:4242`, Meshtastic radio A on, Settings → Relay on, Connect.
- [ ] The Mac probe (instance 1) prints the simulator's ANNOUNCE (relayed by the gateway onto the radio).
- [ ] Probe rerun with `--send <simulator address> --method direct --text "via gateway"`:
      record DELIVERED / FAILED and the time, for the current preset. If it fails, retry at
      ShortTurbo. This is the measurement for the responder's 15 s choice.
- [ ] Opportunistic the same way (`--method opportunistic`): record.

## (d) hopLimit nil → firmware default

ReTiCA always sends hop limit 1 (Contract 2's config is not optional), so the `nil` path is
MeshtasticKit's, exercised through Meshtastified (its text send omits `hop_limit`,
`MeshSessionActor.swift:123-129`).
1. Stop rnsd (it holds radio B's serial port).
2. `conda run --no-capture-output -n rns meshtastic --port <your port from Mac setup step 5> --listen`
   (if `--listen` is unknown in the installed version, use `--debug` instead and read the packet lines).
3. Meshtastified on the iPhone, connected to radio A (ReTiCAMsgr disconnected from it): send a text
   on the public channel.
- [ ] Record the received packet's `hopStart` and `hopLimit`. Expected: `hopStart` = radio A's LoRa
      hop limit (firmware default 3 unless changed).
4. Disconnect Meshtastified, connect ReTiCAMsgr to radio A, tap Announce.
- [ ] Record the port-76 packet's `hopStart` (expected 1).

## Restore radio B's preset (last step)

Stop rnsd, then restore the value you noted in the Equipment table ("original preset of radio B"):
`conda run -n rns meshtastic --port <your port from Mac setup step 5> --set lora.modem_preset <ORIGINAL_NAME>`
(or set it in the Meshtastic app; the radio reboots once). Also restore `~/.reticulum/config` from
`~/.reticulum/config.pre-meshtastic` if you made that copy.
- [ ] Radio B back on its original preset.

## Results

| test | preset | result | latency | notes |
|---|---|---|---|---|
| (a) announce iPhone → Mac | | | | |
| (a) iPhone → Mac message | | | | |
| (a) Mac → iPhone message | | | | |
| (a) long message | | | | |
| (b) A → B | | | | |
| (b) B → A | | | | |
| (b) background | | | | |
| (c) direct via gateway | | | | |
| (c) opportunistic via gateway | | | | |
| (d) Meshtastified hopStart | | | | |
| (d) ReTiCA hopStart | | | | |

Diagnostics counters after (a):
