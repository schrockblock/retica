import Foundation
import Testing

@testable import ReTiCAInterfaces

/// NIC eligibility (spec 2026-11-10 §5.5 rules 1-5 in order, §7.2.1) and link-local selection.
struct AutoInterfaceConfigTests {
    @Test func defaultsAdoptOrdinaryNICs() {
        let c = AutoInterfaceConfig()
        #expect(c.isEligible(nicName: "en0"))
        #expect(c.isEligible(nicName: "bridge100"))
        #expect(c.isEligible(nicName: "eth0"))
    }

    @Test func loopbackIsAlwaysSkippedEvenWhenListed() {
        // Rule 1.
        #expect(!AutoInterfaceConfig().isEligible(nicName: "lo0"))
        #expect(!AutoInterfaceConfig(devices: ["lo0"]).isEligible(nicName: "lo0"))
    }

    @Test func darwinIgnoreListSkippedUnlessListedInDevices() {
        // Rule 2.
        for nic in ["awdl0", "llw0", "en5"] {
            #expect(!AutoInterfaceConfig().isEligible(nicName: nic), "\(nic)")
            #expect(AutoInterfaceConfig(devices: [nic]).isEligible(nicName: nic), "\(nic) listed")
        }
    }

    @Test func ignoredDevicesWinOverDevicesAndOverTheDarwinListOverride() {
        // Rule 3 comes after 2: listed in both devices and ignored_devices is skipped.
        let c = AutoInterfaceConfig(devices: ["en0", "en5"], ignoredDevices: ["en0", "en5"])
        #expect(!c.isEligible(nicName: "en0"))
        #expect(!c.isEligible(nicName: "en5"))
        #expect(!AutoInterfaceConfig(ignoredDevices: ["en1"]).isEligible(nicName: "en1"))
        #expect(AutoInterfaceConfig(ignoredDevices: ["en1"]).isEligible(nicName: "en0"))
    }

    @Test func nonEmptyDevicesIsAnAllowList() {
        // Rule 4.
        let c = AutoInterfaceConfig(devices: ["en0"])
        #expect(c.isEligible(nicName: "en0"))
        #expect(!c.isEligible(nicName: "en1"))
        #expect(!c.isEligible(nicName: "bridge100"))
    }

    @Test func tunnelsAndCellularSkippedUnlessListed() {
        // Rule 5 (ReTiCA addition).
        for nic in ["utun0", "utun9", "ipsec0", "pdp_ip0", "pdp_ip3"] {
            #expect(!AutoInterfaceConfig().isEligible(nicName: nic), "\(nic)")
            #expect(AutoInterfaceConfig(devices: [nic]).isEligible(nicName: nic), "\(nic) listed")
            // Listing a different NIC does not rescue it, and it is excluded by the allow-list anyway.
            #expect(!AutoInterfaceConfig(devices: ["en0"]).isEligible(nicName: nic), "\(nic) other")
        }
        // The prefix match is a prefix: `utunx` style names count, `mutun0` does not.
        #expect(!AutoInterfaceConfig().isEligible(nicName: "utunX"))
        #expect(AutoInterfaceConfig().isEligible(nicName: "mutun0"))
    }

    @Test func ignoredDevicesStillSkipsAListedTunnel() {
        let c = AutoInterfaceConfig(devices: ["utun3"], ignoredDevices: ["utun3"])
        #expect(!c.isEligible(nicName: "utun3"))
    }

    @Test func selectLinkLocalAdoptsTheLastFe80Address() {
        #expect(AutoInterfaceConfig.selectLinkLocal(["fe80::1", "fe80::2"]) == "fe80::2")
        #expect(AutoInterfaceConfig.selectLinkLocal(["fe80::1", "2001:db8::1"]) == "fe80::1")
        #expect(AutoInterfaceConfig.selectLinkLocal(["2001:db8::1"]) == nil)
        #expect(AutoInterfaceConfig.selectLinkLocal([]) == nil)
    }
}
