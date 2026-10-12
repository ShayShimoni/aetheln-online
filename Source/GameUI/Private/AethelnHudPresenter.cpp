#include "AethelnHudPresenter.h"

#include "UObject/Object.h"

#define LOCTEXT_NAMESPACE "AethelnHud"

// Placeholder wording (#61): final text, localization, and visual language are TBD.

FAethelnHudPresenter::~FAethelnHudPresenter()
{
	Unbind();
}

const FAethelnHudView& FAethelnHudPresenter::Refresh(UObject* StateSource, UObject* ObjectiveSource)
{
	IAethelnHudStateSource* State = IsValid(StateSource) ? Cast<IAethelnHudStateSource>(StateSource) : nullptr;
	UObject* StateObject = State != nullptr ? StateSource : nullptr;
	if (StateObject != BoundSource.Get(true) || (StateObject == nullptr && OutcomeHandle.IsValid()))
	{
		Unbind();
		if (State != nullptr)
		{
			BoundSource = StateObject;
			OutcomeHandle = State->OnHudActionOutcome().AddRaw(this, &FAethelnHudPresenter::HandleOutcome);
		}
	}

	const FAethelnHudSnapshot Snapshot = State != nullptr ? State->GetHudSnapshot() : FAethelnHudSnapshot();
	View.Health = FormatResource(LOCTEXT("Health", "Health"), Snapshot.Health);
	View.Endurance = FormatResource(LOCTEXT("Endurance", "Endurance"), Snapshot.Endurance);
	View.Guard = FormatResource(LOCTEXT("Guard", "Guard"), Snapshot.Guard);
	View.TimedStates = FormatTimedStates(Snapshot.TimedStates);
	View.Outcome = FormatOutcome(LastOutcome, OutcomeCount);
	View.OutcomeCount = OutcomeCount;

	IAethelnHudObjectiveSource* ObjectiveOwner = IsValid(ObjectiveSource) ? Cast<IAethelnHudObjectiveSource>(ObjectiveSource) : nullptr;
	const FAethelnHudObjective Objective = ObjectiveOwner != nullptr ? ObjectiveOwner->GetHudObjective() : FAethelnHudObjective();
	View.Objective = FormatObjective(Objective);
	// Only a transition this presenter saw is the completion event, so a recreated HUD never repeats it.
	View.bObjectiveCompletedThisRefresh = ObjectiveOwner != nullptr
		&& ObjectiveSourceSeen.Get() == ObjectiveSource
		&& LastObjectiveState != EAethelnHudObjectiveState::Completed
		&& Objective.State == EAethelnHudObjectiveState::Completed;
	ObjectiveSourceSeen = ObjectiveOwner != nullptr ? ObjectiveSource : nullptr;
	LastObjectiveState = Objective.State;
	return View;
}

void FAethelnHudPresenter::Unbind()
{
	// A source already being destroyed still owns its delegate: remove the handle so it can never call a freed presenter.
	if (UObject* Source = BoundSource.Get(true))
	{
		if (IAethelnHudStateSource* State = Cast<IAethelnHudStateSource>(Source))
		{
			State->OnHudActionOutcome().Remove(OutcomeHandle);
		}
	}
	BoundSource.Reset();
	OutcomeHandle.Reset();
	LastOutcome.Reset();
	OutcomeCount = 0;
	HighestSequence = 0;
}

FText FAethelnHudPresenter::FormatResource(const FText& Label, const FAethelnHudResource& Resource)
{
	if (!Resource.bKnown)
	{
		return FText::Format(LOCTEXT("ResourceUnknown", "{0} --"), Label);
	}
	// TBD placeholder rounding: up, so a living character never reads 0 (and 39.2 of 40 reads 40 / 40).
	return FText::Format(LOCTEXT("Resource", "{0} {1} / {2}"), Label,
		FText::AsNumber(FMath::CeilToInt(Resource.Current)), FText::AsNumber(FMath::RoundToInt(Resource.Max)));
}

FText FAethelnHudPresenter::FormatTimedStates(const TArray<FAethelnHudTimedState>& States)
{
	if (States.IsEmpty())
	{
		return LOCTEXT("NoTimers", "Timers: none");
	}
	FNumberFormattingOptions Tenths;
	Tenths.MinimumFractionalDigits = 1;
	Tenths.MaximumFractionalDigits = 1;
	TArray<FText> Lines;
	for (const FAethelnHudTimedState& State : States)
	{
		// The tag is the working name until display names exist.
		const FText Name = FText::FromName(State.Tag.GetTagName());
		if (State.RemainingSeconds < 0.0f)
		{
			Lines.Add(FText::Format(LOCTEXT("TimerActive", "{0} active"), Name));
			continue;
		}
		// TBD placeholder precision: rounds up to a tenth with a floor of 0.1, so a running timer
		// never reads 0.0 or -0.0; the small bias absorbs float error.
		const float Seconds = FMath::Max(FMath::CeilToFloat(State.RemainingSeconds * 10.0f - 0.001f), 1.0f) / 10.0f;
		Lines.Add(FText::Format(LOCTEXT("TimerSeconds", "{0} {1}s"), Name, FText::AsNumber(Seconds, &Tenths)));
	}
	return FText::Join(FText::FromString(TEXT("\n")), Lines);
}

FText FAethelnHudPresenter::FormatOutcome(const TOptional<FAethelnHudActionOutcome>& Outcome, uint32 Count)
{
	if (!Outcome.IsSet())
	{
		return LOCTEXT("NoOutcome", "Last action: none");
	}
	// The count makes a repeated identical cue visibly new.
	const FText Number = FText::AsNumber(Count);
	switch (Outcome->Kind)
	{
	case EAethelnHudOutcomeKind::Accepted:
		return FText::Format(LOCTEXT("Accepted", "Last action: ACCEPTED #{0}"), Number);
	case EAethelnHudOutcomeKind::Corrected:
		return FText::Format(LOCTEXT("Corrected", "Last action: CORRECTED #{0}"), Number);
	default:
		return Outcome->Reason.IsNone()
			? FText::Format(LOCTEXT("Rejected", "Last action: REJECTED #{0}"), Number)
			: FText::Format(LOCTEXT("RejectedReason", "Last action: REJECTED ({0}) #{1}"), FText::FromName(Outcome->Reason), Number);
	}
}

FText FAethelnHudPresenter::FormatObjective(const FAethelnHudObjective& Objective)
{
	switch (Objective.State)
	{
	case EAethelnHudObjectiveState::Active:
		return FText::Format(LOCTEXT("ObjectiveActive", "Objective: {0}"), Objective.Label);
	case EAethelnHudObjectiveState::Completed:
		return FText::Format(LOCTEXT("ObjectiveCompleted", "Objective complete: {0}"), Objective.Label);
	default:
		return LOCTEXT("NoObjective", "Objective: none");
	}
}

void FAethelnHudPresenter::HandleOutcome(const FAethelnHudActionOutcome& Outcome)
{
	// A step that starts at once sends its record (Corrected) before its request's Accepted outcome;
	// a buffered step sends it later. Either way one action keeps one cue, and Corrected wins.
	if (Outcome.Sequence != 0 && LastOutcome.IsSet() && LastOutcome->Sequence == Outcome.Sequence)
	{
		if (Outcome.Kind == EAethelnHudOutcomeKind::Corrected)
		{
			LastOutcome = Outcome;
		}
		return;
	}
	// A buffered step's late correction never replaces a newer action's cue.
	if (Outcome.Kind == EAethelnHudOutcomeKind::Corrected && Outcome.Sequence != 0 && Outcome.Sequence <= HighestSequence)
	{
		return;
	}
	HighestSequence = FMath::Max(HighestSequence, Outcome.Sequence);
	LastOutcome = Outcome;
	++OutcomeCount;
}

#undef LOCTEXT_NAMESPACE
