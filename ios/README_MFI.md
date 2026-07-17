# OBDLink MX+ on iOS (MFi / ExternalAccessory)

The OBDLink MX+ is MFi-certified, so iOS apps talk to it through Apple's
ExternalAccessory framework — not a serial port. TESTEV does this via the
local `plugins/ea_accessory` plugin.

## How it works

1. Pair the MX+ in **Settings → Bluetooth** (hold its button until it
   blinks). It must show as *Connected* there — iOS, not the app, owns the
   Bluetooth link for MFi accessories.
2. In TESTEV, tap **Connect via Bluetooth**. The app lists connected MFi
   accessories and opens an `EASession` using the first protocol string that
   is both advertised by the accessory and declared in `Info.plist` under
   `UISupportedExternalAccessoryProtocols`.
3. From there the normal TESTEV ELM/STN flow runs (ATZ → filters → ATMA),
   identical to Android.

## If connection fails with "protocol not declared"

OBD Solutions does not publish their protocol string, so `Info.plist` ships
with best-guess candidates. If none match, the error message on the connect
screen prints the strings the MX+ **actually advertises** — e.g.

    OBDLink MX+: com.example.actualstring

Copy that string into `ios/Runner/Info.plist`:

```xml
<key>UISupportedExternalAccessoryProtocols</key>
<array>
    <string>com.example.actualstring</string>
</array>
```

Rebuild, and it will connect. This is a one-time fix — please also update
this file and commit the real string once known.

## App Store note

Sideloaded/dev builds only need the steps above. Distributing an MFi-app on
the App Store additionally requires the accessory maker (OBD Solutions) to
add your app to their MFi product plan — contact them via
https://www.obdlink.com/developers/ if that day comes.
