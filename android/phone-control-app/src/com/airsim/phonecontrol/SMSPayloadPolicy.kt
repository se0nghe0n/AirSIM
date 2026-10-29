package com.airsim.phonecontrol

class SMSPayloadPolicy private constructor() {
    companion object {
        @JvmStatic
        fun validDestination(value: String?): Boolean {
            if (value == null) return false
            val trimmed = (value as java.lang.String).trim()
            if (trimmed.length == 0 || trimmed.length > 82) return false
            var index = 0
            while (index < trimmed.length) {
                val character = trimmed[index]
                val allowed = (character >= '0' && character <= '9') || character == '+' || character == '*'
                    || character == '#' || character == ' ' || character == '-' || character == '('
                    || character == ')'
                if (!allowed) return false
                index++
            }
            return true
        }

        @JvmStatic
        fun normalizeDestination(value: String?): String {
            if (value == null || !validDestination(value)) return ""
            // Drop the same separators as Java String.replace(CharSequence, CharSequence).
            // Kotlin's String.replace(String, String) is a different stdlib method.
            return stripSeparators((value as java.lang.String).trim())
        }

        @JvmStatic
        fun validBody(value: String?): Boolean {
            if (value == null) return false
            val javaValue = value as java.lang.String
            return javaValue.trim().length != 0 && javaValue.codePointCount(0, javaValue.length) <= 2000
        }

        private fun stripSeparators(value: String): String {
            val builder = java.lang.StringBuilder(value.length)
            var index = 0
            while (index < value.length) {
                val character = value[index]
                if (character != ' ' && character != '-' && character != '(' && character != ')') {
                    builder.append(character)
                }
                index++
            }
            return builder.toString()
        }
    }
}
