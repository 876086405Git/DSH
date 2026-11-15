# DNS preparation regression fixture

These files are test-only and are not listed in the production Meson target.
Build the normal confined ARM64 kernel plus dns-fixture.c with
`-DDSH_GUEST_DNS_TEST=1`; this substitutes only the platform resolver provider.
The guest filesystem, task lifecycle, formatter and safe publication path remain
production code. Build dns-probe.c against that library and guest_backend.h plus
guest_dns.h. Run under AArch64 Linux/QEMU with four absolute arguments: a fresh
schema3 Alpine fakefs container, synthetic workspace, separate temp, protected
folder. No network is accessed; RFC documentation addresses are test fixtures.

Run three times, resetting the test root each time. Set `DSH_TEST_ATTACK` to
`target`, `parent`, then `pending` in the host test environment. The probe checks
numeric-input validation and buffer limits, actual fakefs create/readback,
configuration refresh, absent system DNS clearing old nameservers while uname
still works, invalid provider input failing before task admission, and finally
terminal symlink / parent symlink / preexisting staging-file/symlink skipping. Seed a
workspace `sentinel` file and verify its bytes remain unchanged. For the pending
case also confirm legacy and numbered staging files retain their guest-written
bytes, and the numbered symlink does not modify the workspace sentinel.

The fixture macro and DSH_TEST_* environment variables have no effect in the
production build. Linux production builds retain their previous DNS behavior;
Apple production calls the real resolver API, not this fixture. An Apple SDK
compile and device run are still required.
