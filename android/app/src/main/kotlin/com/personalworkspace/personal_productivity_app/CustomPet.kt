package com.personalworkspace.personal_productivity_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** A private, offline portrait-to-sticker effect. The source photo is never copied or uploaded. */
internal object CustomPet {
    private const val SIDE = 384
    private const val MAX_SOURCE_SIDE = 1024
    private const val PREFS = "taskiya"

    fun currentPath(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.getString("pet_kind", "niya") != "custom") return null
        val path = prefs.getString("custom_pet_path", null) ?: return null
        return path.takeIf { File(it).isFile }
    }

    fun savedPath(context: Context): String? = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        .getString("custom_pet_path", null)?.takeIf { File(it).isFile }

    fun importPhoto(context: Context, uri: Uri): String {
        val source = decodeBounded(context, uri)
            ?: throw IllegalArgumentException("This image could not be opened. Choose a JPG or PNG photo.")
        val portrait = try { toonSticker(source) } finally { source.recycle() }
        val directory = File(context.filesDir, "pets").apply { mkdirs() }
        val file = File(directory, "custom_${UUID.randomUUID()}.png")
        try {
            FileOutputStream(file).use { stream ->
                if (!portrait.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
                    throw IllegalStateException("Could not save the custom pet")
                }
                stream.fd.sync()
            }
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val previous = prefs.getString("custom_pet_path", null)
            prefs.edit().putString("custom_pet_path", file.absolutePath)
                .putString("pet_kind", "custom").apply()
            previous?.takeIf { it != file.absolutePath && File(it).parentFile == directory }?.let { File(it).delete() }
            return file.absolutePath
        } catch (error: Exception) {
            file.delete()
            throw error
        } finally {
            portrait.recycle()
        }
    }

    fun select(context: Context, kind: String) {
        require(kind in PetCatalog.choices)
        if (kind == "custom" && savedPath(context) == null) {
            throw IllegalStateException("Choose a photo first")
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString("pet_kind", kind).apply()
    }

    fun remove(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val old = prefs.getString("custom_pet_path", null)
        prefs.edit().putString("pet_kind", "niya").remove("custom_pet_path").apply()
        old?.takeIf { File(it).parentFile == File(context.filesDir, "pets") }?.let { File(it).delete() }
    }

    private fun decodeBounded(context: Context, uri: Uri): Bitmap? {
        return if (Build.VERSION.SDK_INT >= 28) {
            val source = ImageDecoder.createSource(context.contentResolver, uri)
            ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val width = info.size.width
                val height = info.size.height
                if (width <= 0 || height <= 0) throw IllegalArgumentException("Invalid image")
                val scale = min(1.0, MAX_SOURCE_SIDE.toDouble() / max(width, height))
                decoder.setTargetSize(max(1, (width * scale).toInt()), max(1, (height * scale).toInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } else {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
            var sample = 1
            while (max(bounds.outWidth, bounds.outHeight) / sample > MAX_SOURCE_SIDE) sample *= 2
            val options = BitmapFactory.Options().apply { inSampleSize = sample; inPreferredConfig = Bitmap.Config.ARGB_8888 }
            context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
        }
    }

    private fun toonSticker(source: Bitmap): Bitmap {
        val square = Bitmap.createBitmap(SIDE, SIDE, Bitmap.Config.ARGB_8888)
        val squareCanvas = Canvas(square)
        val cropSide = min(source.width, source.height)
        val left = (source.width - cropSide) / 2
        val top = (source.height - cropSide) / 2
        squareCanvas.drawBitmap(source, Rect(left, top, left + cropSide, top + cropSide),
            Rect(0, 0, SIDE, SIDE), Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))

        val original = IntArray(SIDE * SIDE)
        square.getPixels(original, 0, SIDE, 0, 0, SIDE, SIDE)
        val output = IntArray(original.size)
        fun level(value: Int): Int = ((value * 5 + 127) / 255 * 255 / 5).coerceIn(0, 255)
        for (y in 0 until SIDE) for (x in 0 until SIDE) {
            val index = y * SIDE + x
            val pixel = original[index]
            val right = original[y * SIDE + min(x + 2, SIDE - 1)]
            val down = original[min(y + 2, SIDE - 1) * SIDE + x]
            val edge = abs(Color.red(pixel) - Color.red(right)) +
                abs(Color.green(pixel) - Color.green(right)) +
                abs(Color.blue(pixel) - Color.blue(right)) +
                abs(Color.red(pixel) - Color.red(down)) +
                abs(Color.green(pixel) - Color.green(down)) +
                abs(Color.blue(pixel) - Color.blue(down))
            val r = level(Color.red(pixel))
            val g = level(Color.green(pixel))
            val b = level(Color.blue(pixel))
            output[index] = if (edge > 220) Color.rgb(r * 2 / 5, g * 2 / 5, b * 2 / 5)
                else Color.rgb(r, g, b)
        }
        square.setPixels(output, 0, SIDE, 0, 0, SIDE, SIDE)
        val sticker = Bitmap.createBitmap(SIDE, SIDE, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(sticker)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        val inset = 10f
        val oval = RectF(inset, inset, SIDE - inset, SIDE - inset)
        canvas.drawOval(oval, paint.apply { color = Color.rgb(255, 119, 174) })
        canvas.save()
        val inner = RectF(inset + 8, inset + 8, SIDE - inset - 8, SIDE - inset - 8)
        val path = android.graphics.Path().apply { addOval(inner, android.graphics.Path.Direction.CW) }
        canvas.clipPath(path)
        canvas.drawBitmap(square, null, RectF(0f, 0f, SIDE.toFloat(), SIDE.toFloat()),
            Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG))
        canvas.restore()
        square.recycle()
        return sticker
    }
}
