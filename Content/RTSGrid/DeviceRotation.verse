# creative_device.GetTransform() returns the old /UnrealEngine.com/Temporary/SpatialMath types, which clash with
# /Verse.org/SpatialMath in the files that use it; this file converts without importing both there.

using { /Fortnite.com/Devices }
using { /UnrealEngine.com/Temporary/SpatialMath }
using { /Verse.org/SpatialMath }

# A placed device's world rotation as a /Verse.org/SpatialMath rotation.
DeviceRotation(Device:creative_device_base)<transacts>:(/Verse.org/SpatialMath:)rotation =
    FromRotation(Device.GetTransform().Rotation)
