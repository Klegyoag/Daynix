package com.personalworkspace.personal_productivity_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.widget.ImageView

/** Twelve transparent poses per built-in pet, ordered left to right in a 4x3 atlas. */
internal class NiyaFrames(context: Context) {
    companion object {
        const val IDLE = 0
        const val BLINK = 1
        const val HAPPY = 2
        const val WALK = 3
        const val RUN = 4
        const val SLEEP = 5
        const val PEEK = 6
        const val REMINDER = 7
        const val COMPLETED = 8
        const val SAD = 9
        const val THINKING = 10
        const val WAVE = 11
    }

    private val kind = PetCatalog.kind(context)
    private val atlasRes = when (kind) {
        "titta" -> R.drawable.pet_titta_atlas
        "luna" -> R.drawable.pet_luna_atlas
        "kleg" -> R.drawable.pet_kleg_atlas
        "momo" -> R.drawable.pet_momo_atlas
        "custom" -> null
        else -> R.drawable.niya_atlas
    }
    private val atlas = atlasRes?.let { BitmapFactory.decodeResource(context.resources, it) }
    private val staticPet = if (atlas == null) PetCatalog.bitmap(context) else null
    private val cellWidth = (atlas?.width ?: 0) / 4
    private val cellHeight = (atlas?.height ?: 0) / 3
    private val poses = Array(12) { index ->
        if (staticPet != null) return@Array staticPet
        // NIYA's sleeping pose spills into her peeking cell. The four new
        // atlases have clean equal cells and need no crop.
        val leftInset = if (kind == "niya" && index == PEEK) cellWidth * 31 / 100 else 0
        val bottomInset = if (kind == "niya" && index == PEEK) cellHeight / 18 else 0
        Bitmap.createBitmap(
            atlas!!,
            (index % 4) * cellWidth + leftInset,
            (index / 4) * cellHeight,
            cellWidth - leftInset,
            cellHeight - bottomInset,
        )
    }
    private val staticEdge = staticPet?.let { Bitmap.createBitmap(it, it.width / 2, 0, it.width - it.width / 2, it.height) }

    fun show(view: ImageView, pose: Int) {
        view.setImageBitmap(poses[pose.coerceIn(0, poses.lastIndex)])
    }

    fun edgeBitmap(): Bitmap = staticEdge ?: poses[PEEK]

    /** New atlas peeks hold their border on the right; NIYA holds the left. */
    fun edgeScaleX(left: Boolean): Float = if (kind in setOf("titta", "luna", "kleg", "momo")) {
        if (left) -1f else 1f
    } else {
        if (left) 1f else -1f
    }

    fun close() {
        poses.distinct().forEach { if (!it.isRecycled) it.recycle() }
        staticEdge?.let { if (!it.isRecycled) it.recycle() }
        atlas?.let { if (!it.isRecycled) it.recycle() }
    }
}
