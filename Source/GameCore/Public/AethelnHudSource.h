#pragma once

#include "CoreMinimal.h"
#include "GameplayTagContainer.h"
#include "UObject/Interface.h"
#include "AethelnHudSource.generated.h"

/**
 * Presentation-safe HUD contract (#61). GameUI reads player state only through these
 * GameCore types, never through GameCombat. Everything here is read-only presentation:
 * no HUD value or event is ever an input to gameplay.
 */

/** One resource as the local client currently sees it. bKnown is false until the source can read it. */
struct FAethelnHudResource
{
	float Current = 0.0f;
	float Max = 0.0f;
	bool bKnown = false;
};

/** A timed state such as a cooldown. A negative RemainingSeconds means no duration is known. */
struct FAethelnHudTimedState
{
	FGameplayTag Tag;
	float RemainingSeconds = -1.0f;
};

struct FAethelnHudSnapshot
{
	FAethelnHudResource Health;
	FAethelnHudResource Endurance;
	FAethelnHudResource Guard;
	TArray<FAethelnHudTimedState> TimedStates;
};

enum class EAethelnHudOutcomeKind : uint8
{
	Accepted,
	/** Accepted with a server correction, for example a clamped aim. */
	Corrected,
	Rejected
};

/** The server's outcome for one local action. No target, hit, amount, or server-only detail. */
struct FAethelnHudActionOutcome
{
	EAethelnHudOutcomeKind Kind = EAethelnHudOutcomeKind::Accepted;
	/** The request sequence; 0 when the action has none (movement-carried actions). */
	uint32 Sequence = 0;
	/** The owner-facing result name for a rejection (working text, not a final display string). */
	FName Reason;
};

DECLARE_MULTICAST_DELEGATE_OneParam(FAethelnHudActionOutcomeDelegate, const FAethelnHudActionOutcome&);

UINTERFACE(MinimalAPI)
class UAethelnHudStateSource : public UInterface
{
	GENERATED_BODY()
};

/** Implemented by the player's state owner (the PlayerState). */
class GAMECORE_API IAethelnHudStateSource
{
	GENERATED_BODY()

public:
	virtual FAethelnHudSnapshot GetHudSnapshot() const = 0;
	virtual FAethelnHudActionOutcomeDelegate& OnHudActionOutcome() = 0;
};

enum class EAethelnHudObjectiveState : uint8
{
	None,
	Active,
	/** Terminal. */
	Completed
};

struct FAethelnHudObjective
{
	EAethelnHudObjectiveState State = EAethelnHudObjectiveState::None;
	FText Label;
};

UINTERFACE(MinimalAPI)
class UAethelnHudObjectiveSource : public UInterface
{
	GENERATED_BODY()
};

/** Implemented by the authoritative objective owner (#4); tests use a fixture. */
class GAMECORE_API IAethelnHudObjectiveSource
{
	GENERATED_BODY()

public:
	virtual FAethelnHudObjective GetHudObjective() const = 0;
};
