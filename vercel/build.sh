#!/usr/bin/env bash
# Vercel build step. Pushed from GitHub, the Flutter project is one folder up
# (the Vercel project's Root Directory is "vercel"): install Flutter and
# build the web app into public/. Uploaded from a PC with deploy_web.ps1,
# only this folder arrives, with public/ already built: nothing to do.
set -euo pipefail

if [ ! -f ../pubspec.yaml ]; then
  echo "No Flutter project here: using the prebuilt public/ folder."
  exit 0
fi

FLUTTER_VERSION=3.44.8   # same as local; bump together
SDK="$PWD/../.flutter-sdk"
if [ ! -x "$SDK/bin/flutter" ]; then
  git clone --depth 1 --branch "$FLUTTER_VERSION" \
    https://github.com/flutter/flutter.git "$SDK"
fi
export PATH="$SDK/bin:$PATH"
flutter --version

cd ..
flutter pub get
# No API key in the build: the app talks to /api (login, Claude, notes).
flutter build web --release --dart-define=API_BASE=/api
rm -rf vercel/public
cp -r build/web vercel/public
