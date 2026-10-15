"""Writes altstore-source.json: the KNAS source for AltStore, so AltStore shows updates for the KNAS apps.
Run by the build after each test release: python altstore_source.py <tag> <version> <build> <dist folder>"""
import json, os, sys, datetime

tag, version, build, dist = sys.argv[1:5]
repo = os.environ.get("GITHUB_REPOSITORY", "thebust3r/knas-ios")
raw = f"https://raw.githubusercontent.com/{repo}/main"
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
net = "KNAS looks for your KNAS server on your home network."
apps = [
    ("KNAS 42", "io.github.thebust3r.knas42", f"KNAS-42-iPhone-{version}.ipa", "AppIcon",
     "Your KNAS cable box, full screen: the guide, the weather channel, sports and your ErsatzTV channels. Keeps the screen on and can AirPlay to a TV."),
    ("KNAS Remote", "io.github.thebust3r.knas42.remote", f"KNAS-Remote-iPhone-{version}.ipa", "RemoteIcon",
     "A remote for every TV running KNAS: channels, guide, volume, number pad, what's on, and turn off all TVs."),
]
out = {"name": "KNAS 42", "identifier": "io.github.thebust3r.knas42.source", "subtitle": "The KNAS 42 iPhone apps",
       "description": "Test builds of the KNAS 42 iPhone apps. New builds show up here by themselves.",
       "iconURL": f"{raw}/ios/Shared/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
       "website": "https://github.com/thebust3r/knas42", "tintColor": "#ffd23a", "apps": [], "news": []}
for name, bid, ipa, icon, about in apps:
    path = os.path.join(dist, ipa)
    url = f"https://github.com/{repo}/releases/download/{tag}/{ipa}"
    size = os.path.getsize(path)
    out["apps"].append({
        "name": name, "bundleIdentifier": bid, "developerName": "thebust3r", "subtitle": about.split(":")[0],
        "localizedDescription": about, "iconURL": f"{raw}/ios/Shared/Assets.xcassets/{icon}.appiconset/icon-1024.png",
        "tintColor": "#ffd23a", "category": "entertainment",
        "versions": [{"version": version, "buildVersion": build, "date": now, "downloadURL": url, "size": size,
                      "minOSVersion": "15.0", "localizedDescription": f"Test build {build}"}],
        # older AltStore versions read these instead
        "version": version, "versionDate": now, "downloadURL": url, "size": size,
        "appPermissions": {"entitlements": [], "privacy": {"NSLocalNetworkUsageDescription": net}},
    })
with open("altstore-source.json", "w") as f:
    json.dump(out, f, indent=2)
print(json.dumps(out, indent=2)[:600])
