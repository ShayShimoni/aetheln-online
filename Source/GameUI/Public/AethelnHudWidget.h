#pragma once

#include "AethelnHudPresenter.h"
#include "Blueprint/UserWidget.h"
#include "CoreMinimal.h"
#include "AethelnHudWidget.generated.h"

class STextBlock;

/**
 * Placeholder player-state HUD (#61): plain text lines, no art. Visual language,
 * cue timing and localization are TBD. Each tick it presents the owning player's
 * PlayerState and the GameState objective through FAethelnHudPresenter; it stays
 * collapsed while the PlayerState is not a HUD source (for example in the movement POC).
 */
UCLASS()
class GAMEUI_API UAethelnHudWidget : public UUserWidget
{
	GENERATED_BODY()

public:
	UAethelnHudWidget(const FObjectInitializer& ObjectInitializer);

protected:
	virtual TSharedRef<SWidget> RebuildWidget() override;
	virtual void NativeTick(const FGeometry& MyGeometry, float InDeltaTime) override;
	virtual void NativeDestruct() override;
	virtual void ReleaseSlateResources(bool bReleaseChildren) override;

private:
	FAethelnHudPresenter Presenter;
	/** Collapsed instead of the widget itself, which must keep ticking to notice a source. */
	TSharedPtr<SWidget> Panel;
	TSharedPtr<STextBlock> Lines;
};
