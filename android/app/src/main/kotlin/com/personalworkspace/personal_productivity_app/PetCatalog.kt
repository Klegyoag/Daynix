package com.personalworkspace.personal_productivity_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory

/** One persisted pet choice drives the overlay, assistant panel, and notification. */
internal object PetCatalog {
    val choices = setOf("niya", "titta", "luna", "kleg", "momo", "custom")

    fun kind(context: Context): String {
        val value = context.getSharedPreferences("taskiya", Context.MODE_PRIVATE)
            .getString("pet_kind", "niya") ?: "niya"
        return when {
            value !in choices -> "niya"
            value == "custom" && CustomPet.savedPath(context) == null -> "niya"
            else -> value
        }
    }

    fun name(context: Context): String = when (kind(context)) {
        "titta" -> "Titta"
        "luna" -> "Luna"
        "kleg" -> "Kleg"
        "momo" -> "Momo"
        "custom" -> "My pet"
        else -> "NIYA"
    }

    fun drawable(context: Context): Int = when (kind(context)) {
        "titta" -> R.drawable.pet_titta
        "luna" -> R.drawable.pet_luna
        "kleg" -> R.drawable.pet_kleg
        "momo" -> R.drawable.pet_momo
        else -> R.drawable.niya_idle
    }

    fun bitmap(context: Context): Bitmap? =
        CustomPet.currentPath(context)?.let { BitmapFactory.decodeFile(it) }
            ?: BitmapFactory.decodeResource(context.resources, drawable(context))
}
