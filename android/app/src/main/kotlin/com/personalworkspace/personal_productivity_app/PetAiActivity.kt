package com.personalworkspace.personal_productivity_app

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.android.FlutterActivityLaunchConfigs

/** Separate translucent task so the pet chat never enters the app's Recents card. */
class PetAiActivity : FlutterFragmentActivity() {
    override fun getInitialRoute(): String = "/pet-ai"
    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent
}
