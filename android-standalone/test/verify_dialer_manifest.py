#!/usr/bin/env python3
import sys
import xml.etree.ElementTree as ET


ANDROID = "{http://schemas.android.com/apk/res/android}"
if len(sys.argv) != 2:
    sys.exit("Usage: verify_dialer_manifest.py SOURCE_MANIFEST < BUILT_MANIFEST")

source = ET.parse(sys.argv[1]).getroot()
root = ET.fromstring(sys.stdin.read())

for attribute in ("package", ANDROID + "versionCode", ANDROID + "versionName"):
    expected = source.get(attribute)
    if not expected or root.get(attribute) != expected:
        name = attribute.removeprefix(ANDROID)
        sys.exit(f"FAIL: built Standalone APK {name} does not match source manifest")

def component_name(item):
    name = item.get(ANDROID + "name", "")
    if name.startswith("."):
        return root.get("package", "") + name
    if "." not in name:
        return root.get("package", "") + "." + name
    return name

permissions = {
    item.get(ANDROID + "name") for item in root.findall("uses-permission")
}
if "android.permission.USE_FULL_SCREEN_INTENT" not in permissions:
    print("FAIL: built Standalone APK cannot request a full-screen incoming-call UI", file=sys.stderr)
    sys.exit(1)

call_activity = next((item for item in root.findall("./application/activity")
    if component_name(item) == "com.airsim.phonecontrol.CallScreenActivity"), None)
if (call_activity is None
        or call_activity.get(ANDROID + "exported") != "false"
        or call_activity.get(ANDROID + "showWhenLocked") != "true"
        or call_activity.get(ANDROID + "turnScreenOn") != "true"):
    print("FAIL: built Standalone APK lacks a private lock-screen call UI", file=sys.stderr)
    sys.exit(1)

action_receiver = next((item for item in root.findall("./application/receiver")
    if component_name(item) == "com.airsim.phonecontrol.CallNotificationActionReceiver"), None)
if action_receiver is None or action_receiver.get(ANDROID + "exported") != "false":
    print("FAIL: built Standalone APK lacks a private call-action receiver", file=sys.stderr)
    sys.exit(1)

for activity in root.findall("./application/activity"):
    if component_name(activity) != "com.airsim.phonecontrol.MainActivity":
        continue
    for intent_filter in activity.findall("intent-filter"):
        actions = {item.get(ANDROID + "name") for item in intent_filter.findall("action")}
        categories = {item.get(ANDROID + "name") for item in intent_filter.findall("category")}
        if ("android.intent.action.DIAL" in actions
                and "android.intent.category.DEFAULT" in categories
                and not intent_filter.findall("data")):
            sys.exit(0)

print("FAIL: built Standalone APK lacks the generic ACTION_DIAL filter required for ROLE_DIALER", file=sys.stderr)
sys.exit(1)
