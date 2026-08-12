#pragma once

#include "CoreMinimal.h"

namespace AethelnNetworkSpike
{
	inline constexpr TCHAR NetworkProfileSchemaId[] = TEXT("aetheln.network-profile");
	inline constexpr uint32 NetworkProfileSchemaVersion = 1;
	inline constexpr TCHAR UnsetNetworkProfileId[] = TEXT("network-profile.unset");
}

/**
 * Versioned network conditions applied to a candidate run.
 *
 * Numeric values intentionally remain unset until Issues #2 and #45 record and
 * approve representative measurements. An unset value must not be interpreted
 * as zero, disabled, unlimited, or an engine default.
 */
struct GAMENET_API FAethelnNetworkProfile
{
	FString SchemaId = AethelnNetworkSpike::NetworkProfileSchemaId;
	uint32 SchemaVersion = AethelnNetworkSpike::NetworkProfileSchemaVersion;
	FString ProfileId = AethelnNetworkSpike::UnsetNetworkProfileId;

	TOptional<double> LatencyMilliseconds;
	TOptional<double> JitterMilliseconds;
	TOptional<double> PacketLossPercent;
	TOptional<double> PacketDuplicationPercent;
	TOptional<double> PacketReorderPercent;
	TOptional<double> ServerTickHertz;
	TOptional<double> CombatHistoryMilliseconds;
	TOptional<int64> BandwidthBitsPerSecond;
	TOptional<int32> ConnectionCapacity;

	bool HasUnsetNumericValues() const
	{
		return !LatencyMilliseconds.IsSet()
			|| !JitterMilliseconds.IsSet()
			|| !PacketLossPercent.IsSet()
			|| !PacketDuplicationPercent.IsSet()
			|| !PacketReorderPercent.IsSet()
			|| !ServerTickHertz.IsSet()
			|| !CombatHistoryMilliseconds.IsSet()
			|| !BandwidthBitsPerSecond.IsSet()
			|| !ConnectionCapacity.IsSet();
	}
};
