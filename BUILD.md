# Building Manna

This guide covers requirements, supported platforms/services, and high-level steps to build Manna from source.

Manna is a **Flutter** app with a **Rust** core (via Flutter Rust Bridge / UniFFI). Spark wallet functionality uses **Breez SDK**.

**NOTE: This build steps won't produce the completely working app as the production one, because that requires setting up external services.**

## Requirements

### Supported build platforms
- **MacOS**

**Require 30GB storage**

### Core tools
- **Flutter**
- **Rust** toolchain
- **Git**

### Platform-specific
| Platform    | Extra requirements |
|-------------|--------------------|
| Android     | Android SDK, NDK   |
| iOS / macOS | Xcode              |

## External services
| Service                                                                     | Required | Purpose                                    |
|-----------------------------------------------------------------------------|----------|--------------------------------------------|
| **Supabase** ([Setup](https://github.com/orgs/MannaBitcoin/manna_supabase)) | Yes      | Database, Chat                             |
| **Backend** ([Setup](https://github.com/orgs/MannaBitcoin/manna_backend))   | Yes      | Auth, LNURL, Notifications                 |
| **Firebase**                                                                | No       | Push notifications, Crashlytics, Analytics |

## High-level build steps

1. **Clone the repository**
   ```bash
   git clone https://github.com/orgs/MannaBitcoin/manna_app
   cd manna_app
   mv .env.example .env
   ```

2. Update [ENV](.env). Then run
    ```bash
   sh update_env.sh
   ```

3. **Run**
   ```bash
   flutter run
   ```

## Development notes

- Most of the cryptographic code is in rust enclosed in manna_core package. That rust project is built and bundled into main flutter app via dart build tool.
- If you make any changes to the manna_core rust code, make sure to run
```bash
sh ./packages/manna_core/codegen.sh
```
- When app is not in foreground, swap processing and chat message decryption is handled by notifications, This [code](packages/manna_core/rust/src/nse) handles those notification on Android and iOS, and is called by native platforms via uniffi.
  - So if you make any changes that affects notification processing, make sure to run 
  ```bash
  sh ./packages/manna_core/codegen.sh
  sh ./packages/manna_core/rust/build_nse_android.sh
  sh ./packages/manna_core/rust/build_nse_ios.sh
  ``` 
- Sensitive data stays on-device, it's implemented in manna_core package, on android it uses KeyStore and on apple devices it uses secure enclave.
- For testing you need a Complete regtest setup.
- Notifications require Firebase setup and running backend along with some native setup.

- First Rust native build can take some time depending on the machine.
