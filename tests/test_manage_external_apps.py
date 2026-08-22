#!/usr/bin/env python3
"""What a tag-prefixed app gets wrong silently.

`--tag-prefix` exists because some repos cut one release per platform under
separate tags (getagentseal/codeburn: desktop-v*, mac-v*, windows-v*), so
/releases/latest is whichever platform shipped last and carries no Linux build.
Every failure it introduces is quiet — an app that reports "up to date" forever,
a downgrade offered to a prerelease, an asset pattern that matches nothing —
so none of them announces itself on the machine that has it.

Run: python3 tests/test_manage_external_apps.py
"""

import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "manage_external_apps",
    Path(__file__).resolve().parent.parent / "tools" / "manage-external-apps.py",
)
mea = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mea)

PREFIX = "desktop-"
failures = 0


def check(label, actual, expected):
    global failures
    if actual == expected:
        print(f"  ok   {label}")
    else:
        print(f"  FAIL {label}: got {actual!r}, expected {expected!r}")
        failures += 1


def test_release_selection():
    """The prefix filter picks the newest matching release — and only on the
    channel asked for. The stable channel has to re-apply the prerelease test
    itself: it left /releases/latest, which was doing that implicitly."""
    listing = [
        {"tag_name": "windows-v0.9.21", "prerelease": False, "draft": False},
        {"tag_name": "desktop-v0.9.22", "prerelease": False, "draft": True},
        {"tag_name": "desktop-v0.9.21", "prerelease": True, "draft": False},
        {"tag_name": "mac-v0.9.21", "prerelease": False, "draft": False},
        {"tag_name": "desktop-v0.9.20", "prerelease": False, "draft": False},
        {"tag_name": "desktop-v0.9.19", "prerelease": False, "draft": False},
    ]
    calls = []

    def fake_get(url):
        calls.append(url)
        return listing if "releases?" in url else {"tag_name": "windows-v0.9.21"}

    mea._gh_get_json = fake_get
    mea._release_cache.clear()

    check("stable skips other platforms, drafts and prereleases",
          mea.github_latest_tag("o/r", False, PREFIX), "desktop-v0.9.20")
    mea._release_cache.clear()
    check("prerelease channel takes the newest desktop- prerelease",
          mea.github_latest_tag("o/r", True, PREFIX), "desktop-v0.9.21")
    mea._release_cache.clear()
    check("no prefix still uses /releases/latest",
          mea.github_latest_tag("o/r"), "windows-v0.9.21")

    # A tag_name of null (rather than a missing key) must not abort the whole
    # scan for every other app.
    mea._release_cache.clear()
    listing.insert(0, {"tag_name": None, "prerelease": False, "draft": False})
    check("a null tag_name does not raise",
          mea.github_latest_tag("o/r", False, PREFIX), "desktop-v0.9.20")

    # One HTTP call per distinct (repo, channel, prefix), not one per question.
    mea._release_cache.clear()
    calls.clear()
    mea.github_latest_tag("o/r", False, PREFIX)
    mea.github_latest_tag("o/r", False, PREFIX)
    check("release JSON is fetched once per key", len(calls), 1)


def test_version_comparison_strips_the_prefix():
    """The prefix must come off before the tag is read as a version. Left on, it
    hijacks the partition() in version_key(): "desktop-v1.0.0" parses as release
    "desktop" with an empty numeric part."""
    check("newer prefixed release is outdated",
          mea.version_is_outdated("desktop-v0.9.20", "desktop-v0.9.21", PREFIX), True)
    check("older prefixed release is not a downgrade",
          mea.version_is_outdated("desktop-v0.9.21", "desktop-v0.9.20", PREFIX), False)
    # A Distrobox app's installed version comes from the container's package
    # database, so it is never prefixed — this is the asymmetric comparison.
    check("bare installed vs prefixed latest",
          mea.version_is_outdated("0.9.20", "desktop-v0.9.21", PREFIX), True)
    check("bare installed already ahead",
          mea.version_is_outdated("0.9.21", "desktop-v0.9.20", PREFIX), False)
    # version_key's own invariant, which the prefix inverted.
    check("a prerelease does not supersede its release",
          mea.version_is_outdated("desktop-v1.0.0", "desktop-v1.0.0-beta1", PREFIX), False)
    check("a release does supersede its prerelease",
          mea.version_is_outdated("desktop-v1.0.0-beta1", "desktop-v1.0.0", PREFIX), True)
    check("versions_match through the prefix",
          mea.versions_match("desktop-v4.7.4", "1:4.7.4-1", PREFIX), True)


def test_unprefixed_apps_are_untouched():
    """Every tracked app that predates the flag passes tag_prefix="", so the
    strip has to be a no-op for them."""
    check("helium is outdated", mea.version_is_outdated("0.15.5.1", "v0.15.6.1"), True)
    check("epoch + package revision still match",
          mea.versions_match("v4.7.4", "1:4.7.4-1"), True)
    check("prerelease ordering preserved",
          mea.version_is_outdated("v1.0.0", "v1.0.0-beta1"), False)
    check("state written before TAG_PREFIX existed reads as no filter",
          mea.source_tag_prefix({"APP_NAME": "helium", "PRERELEASE": "0"}), "")


def test_derive_asset_pattern():
    """An asset is named after the version, never after the platform tag, so the
    prefix has to come off or the pattern pins the current filename."""
    check("prefixed tag yields a reusable glob",
          mea.derive_asset_pattern("CodeBurn-0.9.20.AppImage", "desktop-v0.9.20", PREFIX),
          "CodeBurn-*.AppImage")
    check("unprefixed unchanged",
          mea.derive_asset_pattern("helium-0.15.5.1-x86_64.AppImage", "v0.15.5.1"),
          "helium-*-x86_64.AppImage")


def test_prefetch_normalizes_its_input():
    """`latest-release` passes bare repo strings, `check-updates` passes triples.
    Both have to reach gh_release_json with three positional arguments."""
    seen = []
    mea._release_cache.clear()
    mea._gh_get_json = lambda url: (seen.append(url), {"tag_name": "v1"})[1]
    mea.prefetch_release_json(["o/r", ("o/r2", True, PREFIX)])
    check("both input shapes fetch", len(seen), 2)


def main():
    for test in (test_release_selection,
                 test_version_comparison_strips_the_prefix,
                 test_unprefixed_apps_are_untouched,
                 test_derive_asset_pattern,
                 test_prefetch_normalizes_its_input):
        print(test.__name__)
        test()
    print("FAILED" if failures else "ok", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
