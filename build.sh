#!/bin/sh

xcrun xcodebuild clean build -project BillionRowChallenge.xcodeproj -target CreateMeasurements -target BillionRowChallenge -target ChatGPT
ls -lah ./build/Release/
