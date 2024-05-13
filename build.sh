#!/bin/sh

xcrun xcodebuild clean build -project BillionRowChallenge.xcodeproj -target CreateMeasurements -target BillionRowChallenge
ls -lah ./build/Release/
