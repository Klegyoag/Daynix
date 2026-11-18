package com.personalworkspace.personal_productivity_app

import java.time.LocalDateTime

internal object Recurrence {
    fun next(due: String, rule: String, now: LocalDateTime = LocalDateTime.now()): String? {
        if(rule == "none") return null
        val start=try { LocalDateTime.parse(due) } catch (_:Exception) { return null }
        val days=when {
            rule=="weekdays" -> setOf(1,2,3,4,5)
            rule.startsWith("custom:") -> rule.removePrefix("custom:").split(',').mapNotNull { it.toIntOrNull() }.filter { it in 1..7 }.toSet()
            else -> emptySet()
        }
        var candidate=start
        repeat(3660) {
            candidate=when(rule) {
                "daily","weekdays" -> candidate.plusDays(1)
                "weekly" -> candidate.plusWeeks(1)
                "monthly" -> candidate.plusMonths(1)
                else -> if(days.isNotEmpty()) candidate.plusDays(1) else return null
            }
            if(candidate.isAfter(now) && (days.isEmpty() || candidate.dayOfWeek.value in days)) return candidate.toString()
        }
        return null
    }
}
