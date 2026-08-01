#pragma once

#include "Blueprint/UserWidget.h"
#include "CoreMinimal.h"
#include "AethelnPOCOverlayWidget.generated.h"

class STextBlock;

/**
 * Lightweight, non-interactive movement POC label and keyboard/mouse reminder.
 */
UCLASS(meta = (DisableNativeTick))
class GAMEUI_API UAethelnPOCOverlayWidget : public UUserWidget
{
	GENERATED_BODY()

public:
	UAethelnPOCOverlayWidget(const FObjectInitializer& ObjectInitializer);
	void SetControlMode(bool bReticleMode);

protected:
	virtual TSharedRef<SWidget> RebuildWidget() override;

private:
	TSharedPtr<STextBlock> AimReticle;
	TSharedPtr<STextBlock> ModeStatus;
};
