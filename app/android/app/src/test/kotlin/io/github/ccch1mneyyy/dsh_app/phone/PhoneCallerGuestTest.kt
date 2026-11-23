package io.github.ccch1mneyyy.dsh_app.phone

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PhoneCallerGuestTest {
    @Test fun diagnosticsPresetDeniesInheritedToolsAndOwnsCompletePersonaWithoutRuntimeContext() {
        val yaml = PhoneGuest.DIAGNOSTICS_PRESET_YAML
        assertTrue(yaml.startsWith("    - id: preset-dsh-go-diagnostics\n"))
        assertTrue(yaml.contains("        id: dsh-go-diagnostics\n"))
        assertTrue(yaml.contains("              complete: true\n"))
        assertTrue(yaml.contains("              includeRuntimeContext: false\n"))
        assertEquals(listOf("@deepseek-ai/dsh-agent-preset", "/opt/dsh-app/phone/diagnostics-policy.mjs",
            "@deepseek-ai/dsh-tool-executor-native", "@deepseek-ai/dsh-persona"),
            Regex("name: '([^']+)'").findAll(yaml).map { it.groupValues[1] }.toList())
        assertEquals(3, Regex("(?m)^          - id:").findAll(yaml).count())
        assertTrue(PhoneGuest.DIAGNOSTICS_POLICY_JS.contains("export const inject = ['tools'];"))
        assertTrue(PhoneGuest.DIAGNOSTICS_POLICY_JS.contains("ctx.tools.restrict({ allow: [] });"))
        for (forbidden in listOf("dsh-mcp-client", "permission", "command-plan", "skills", "AGENTS.md")) {
            assertFalse(forbidden, yaml.contains(forbidden))
        }
    }

    @Test fun onlyInstalledCallerPatchEnablesManagedStdioOptIn() {
        val root = Files.createTempDirectory("phone-caller-guest").toFile()
        try {
            val info = File(root, "etc/dsh-app/runtime.json")
            assertEquals(PhoneGuest.PATCH_YAML + PhoneGuest.DIAGNOSTICS_PRESET_YAML, PhoneGuest.patchYaml(root))
            info.parentFile.mkdirs()
            for (text in listOf("not json", "{}", "{\"dshPatches\":[\"unrelated.diff\"]}")) {
                info.writeText(text)
                assertEquals(PhoneGuest.PATCH_YAML + PhoneGuest.DIAGNOSTICS_PRESET_YAML, PhoneGuest.patchYaml(root))
            }
            info.writeText(Json.write(mapOf("dshPatches" to listOf(PhoneGuest.CALLER_PATCH))))
            PhoneGuest.writeFiles(root, "export const name = 'phone-skills-test';")
            val overlay = PhoneGuest.guestFile(root, PhoneGuest.PATCH).readText()
            assertEquals(PhoneGuest.PATCH_YAML + "        dshGoPhoneCaller: true\n" +
                "    - id: dsh-app-phone-skills\n      name: '" + PhoneGuest.SKILLS + "'\n" +
                PhoneGuest.DIAGNOSTICS_PRESET_YAML, overlay)
            assertTrue(overlay.indexOf("dshGoPhoneCaller: true") < overlay.indexOf("    - id: preset-dsh-go-diagnostics"))
            assertEquals(PhoneGuest.RELAY_JS, PhoneGuest.guestFile(root, PhoneGuest.RELAY).readText())
            assertEquals(PhoneGuest.DIAGNOSTICS_POLICY_JS, PhoneGuest.guestFile(root, PhoneGuest.DIAGNOSTICS_POLICY).readText())
            assertEquals("export const name = 'phone-skills-test';", PhoneGuest.guestFile(root, PhoneGuest.SKILLS).readText())
        } finally {
            root.deleteRecursively()
        }
    }
}
