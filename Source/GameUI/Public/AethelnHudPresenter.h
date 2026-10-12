#pragma once

#include "AethelnHudSource.h"
#include "CoreMinimal.h"

/** Formatted HUD lines. Every cue is words, never color alone. */
struct FAethelnHudView
{
	FText Health;
	FText Endurance;
	FText Guard;
	FText TimedStates;
	FText Objective;
	FText Outcome;
	/** Outcomes shown since the current state source was bound. */
	uint32 OutcomeCount = 0;
	/** True only on the refresh that first sees the bound objective source turn Completed. */
	bool bObjectiveCompletedThisRefresh = false;
};

/**
 * Presentation logic for the prototype HUD (#61), kept out of the widget so it is testable.
 * Pulls a fresh snapshot on every refresh, so displayed values always converge to what the
 * sources currently hold, and keeps at most one outcome binding: to the latest state source,
 * removed when the source changes and when the presenter is destroyed.
 */
class GAMEUI_API FAethelnHudPresenter
{
public:
	FAethelnHudPresenter() = default;
	FAethelnHudPresenter(const FAethelnHudPresenter&) = delete;
	FAethelnHudPresenter& operator=(const FAethelnHudPresenter&) = delete;
	~FAethelnHudPresenter();

	/** Sources that do not implement their interface, and null, count as absent. */
	const FAethelnHudView& Refresh(UObject* StateSource, UObject* ObjectiveSource);
	void Unbind();

	static FText FormatResource(const FText& Label, const FAethelnHudResource& Resource);
	static FText FormatTimedStates(const TArray<FAethelnHudTimedState>& States);
	static FText FormatOutcome(const TOptional<FAethelnHudActionOutcome>& Outcome, uint32 Count);
	static FText FormatObjective(const FAethelnHudObjective& Objective);

private:
	void HandleOutcome(const FAethelnHudActionOutcome& Outcome);

	TWeakObjectPtr<UObject> BoundSource;
	FDelegateHandle OutcomeHandle;
	TOptional<FAethelnHudActionOutcome> LastOutcome;
	uint32 OutcomeCount = 0;
	TWeakObjectPtr<UObject> ObjectiveSourceSeen;
	EAethelnHudObjectiveState LastObjectiveState = EAethelnHudObjectiveState::None;
	FAethelnHudView View;
};
