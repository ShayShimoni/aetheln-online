#include "AethelnHudWidget.h"

#include "Engine/World.h"
#include "GameFramework/GameStateBase.h"
#include "GameFramework/PlayerController.h"
#include "GameFramework/PlayerState.h"
#include "Styling/CoreStyle.h"
#include "Widgets/Layout/SBorder.h"
#include "Widgets/SOverlay.h"
#include "Widgets/Text/STextBlock.h"

UAethelnHudWidget::UAethelnHudWidget(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer)
{
	SetIsFocusable(false);
	SetVisibility(ESlateVisibility::HitTestInvisible);
}

TSharedRef<SWidget> UAethelnHudWidget::RebuildWidget()
{
	// Placeholder presentation: the engine's default font and panel brush; no project art.
	// Placement, padding, and font size are TBD placeholders.
	return SNew(SOverlay)
		+ SOverlay::Slot()
		.HAlign(HAlign_Left)
		.VAlign(VAlign_Bottom)
		.Padding(FMargin(24.0f))
		[
			SAssignNew(Panel, SBorder)
			.BorderImage(FCoreStyle::Get().GetBrush("ToolPanel.GroupBorder"))
			.Padding(FMargin(12.0f, 8.0f))
			.Visibility(EVisibility::Collapsed)
			[
				SAssignNew(Lines, STextBlock)
				.Font(FCoreStyle::GetDefaultFontStyle("Bold", 14))
			]
		];
}

void UAethelnHudWidget::NativeTick(const FGeometry& MyGeometry, float InDeltaTime)
{
	Super::NativeTick(MyGeometry, InDeltaTime);

	const APlayerController* PlayerController = GetOwningPlayer();
	APlayerState* PlayerState = PlayerController != nullptr ? PlayerController->PlayerState.Get() : nullptr;
	const UWorld* World = GetWorld();
	AGameStateBase* GameState = World != nullptr ? World->GetGameState() : nullptr;
	const FAethelnHudView& View = Presenter.Refresh(PlayerState, GameState);

	const bool bHasSource = Cast<IAethelnHudStateSource>(PlayerState) != nullptr;
	if (Panel.IsValid())
	{
		Panel->SetVisibility(bHasSource ? EVisibility::HitTestInvisible : EVisibility::Collapsed);
	}
	if (bHasSource && Lines.IsValid())
	{
		// View.bObjectiveCompletedThisRefresh is the completion event; its extra cue (timing, sound) is TBD.
		FString Text = FString::Printf(TEXT("%s\n%s\n%s\n%s\n%s\n%s"), *View.Health.ToString(), *View.Endurance.ToString(),
			*View.Guard.ToString(), *View.TimedStates.ToString(), *View.Objective.ToString(), *View.Outcome.ToString());
		if (Text != ShownText)
		{
			ShownText = MoveTemp(Text);
			Lines->SetText(FText::FromString(ShownText));
		}
	}
}

void UAethelnHudWidget::NativeDestruct()
{
	Presenter.Unbind();
	Super::NativeDestruct();
}

void UAethelnHudWidget::ReleaseSlateResources(bool bReleaseChildren)
{
	Super::ReleaseSlateResources(bReleaseChildren);
	Panel.Reset();
	Lines.Reset();
	ShownText.Reset();
}
