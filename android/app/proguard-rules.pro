-dontwarn java.awt.**

-keep class uniffi.** { *; }
-keepclassmembers class uniffi.** { *; }

-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
