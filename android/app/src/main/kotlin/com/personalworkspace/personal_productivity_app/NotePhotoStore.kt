package com.personalworkspace.personal_productivity_app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.ImageDecoder
import android.graphics.Paint
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import java.io.File
import java.io.FileOutputStream
import java.util.UUID

internal object NotePhotoStore {
    fun importPhoto(context: Context, uri: Uri): String {
        val decoded = decodePhoto(context, uri)
        val scale = minOf(1.0, 1600.0 / maxOf(decoded.width, decoded.height))
        val targetWidth = maxOf(1, (decoded.width * scale).toInt())
        val targetHeight = maxOf(1, (decoded.height * scale).toInt())
        val output = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
        Canvas(output).apply {
            drawColor(Color.WHITE)
            drawBitmap(decoded, null, Rect(0, 0, targetWidth, targetHeight), Paint(Paint.FILTER_BITMAP_FLAG))
        }
        decoded.recycle()
        val directory = File(context.filesDir, "note_photos").apply { mkdirs() }
        val file = File(directory, UUID.randomUUID().toString() + ".jpg")
        try {
            FileOutputStream(file).use {
                check(output.compress(Bitmap.CompressFormat.JPEG, 86, it)) { "Could not save photo" }
            }
        } catch (error: Exception) {
            file.delete()
            throw error
        } finally {
            output.recycle()
        }
        return file.absolutePath
    }

    private fun decodePhoto(context: Context, uri: Uri): Bitmap {
        if (Build.VERSION.SDK_INT >= 28) {
            val source = ImageDecoder.createSource(context.contentResolver, uri)
            return ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val width = info.size.width
                val height = info.size.height
                require(width in 1..30000 && height in 1..30000) { "Image dimensions are unsupported" }
                val scale = minOf(1.0, 1600.0 / maxOf(width, height))
                decoder.setTargetSize(maxOf(1, (width * scale).toInt()), maxOf(1, (height * scale).toInt()))
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        }
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, bounds)
        } ?: throw IllegalArgumentException("Image unavailable")
        val width = bounds.outWidth
        val height = bounds.outHeight
        require(width in 1..30000 && height in 1..30000) { "Image dimensions are unsupported" }
        var sample = 1
        while (maxOf(width, height) / sample > 1600) sample *= 2
        return context.contentResolver.openInputStream(uri)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: throw IllegalArgumentException("Could not read image")
    }

    fun delete(context: Context, path: String): Boolean {
        val directory = File(context.filesDir, "note_photos").canonicalFile
        val file = File(path).canonicalFile
        require(file.parentFile == directory && file.name.endsWith(".jpg")) {
            "Invalid note photo path"
        }
        return !file.exists() || file.delete()
    }
}