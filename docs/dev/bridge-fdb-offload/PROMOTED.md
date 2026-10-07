# Promoted to the build tree

The four bridge-FDB-offload patches that used to live here were promoted into
`target/linux/airoha/patches-6.18/` as `931-` .. `934-` once they had passed the
compile verification recorded in `BUILD-VERIFICATION.md`. From that point on they
are applied by every build of this tree (Actions included).

**They are still not tested on hardware.** The limitations documented in
`README.md` still apply verbatim: v1 only offloads untagged unicast FDB entries
(so a `vlan_filtering` bridge such as `pon0:t` + `lan1:u*` with VLAN 3114 is left
to the software bridge), flooding/multicast stay in software, the P-bit is not
programmed, and the 300 s bridge FDB ageing problem is only *measured* by 934,
not solved.
