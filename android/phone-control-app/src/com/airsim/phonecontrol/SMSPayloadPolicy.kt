package com.airsim.phonecontrol

object SMSPayloadPolicy {
    // Java String.trim() strips chars <= U+0020; Kotlin's trim() strips Unicode whitespace.
    private fun String.javaTrim(): String = trim { it <= ' ' }

    @JvmStatic
    fun validDestination(value: String?): Boolean {
        val trimmed = value?.javaTrim() ?: return false
        if (trimmed.length == 0 || trimmed.length > 82) return false
        return trimmed.all { it in '0'..'9' || it in "+*# -()" }
    }

    @JvmStatic
    fun normalizeDestination(value: String?): String {
        if (value == null || !validDestination(value)) return ""
        return value.javaTrim().filterNot { it in " -()" }
    }

    @JvmStatic
    fun validBody(value: String?): Boolean =
        value != null && value.javaTrim().length != 0 && value.codePointCount(0, value.length) <= 2000
}
