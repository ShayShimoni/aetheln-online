#include "AethelnHudPresenter.h"

// Red-first stub (#61): replaced by the implementation after the failing test run.

FAethelnHudPresenter::~FAethelnHudPresenter()
{
}

const FAethelnHudView& FAethelnHudPresenter::Refresh(UObject* StateSource, UObject* ObjectiveSource)
{
	return View;
}

void FAethelnHudPresenter::Unbind()
{
}

FText FAethelnHudPresenter::FormatResource(const FText& Label, const FAethelnHudResource& Resource)
{
	return FText::GetEmpty();
}

FText FAethelnHudPresenter::FormatTimedStates(const TArray<FAethelnHudTimedState>& States)
{
	return FText::GetEmpty();
}

FText FAethelnHudPresenter::FormatOutcome(const TOptional<FAethelnHudActionOutcome>& Outcome, uint32 Count)
{
	return FText::GetEmpty();
}

FText FAethelnHudPresenter::FormatObjective(const FAethelnHudObjective& Objective)
{
	return FText::GetEmpty();
}

void FAethelnHudPresenter::HandleOutcome(const FAethelnHudActionOutcome& Outcome)
{
}
