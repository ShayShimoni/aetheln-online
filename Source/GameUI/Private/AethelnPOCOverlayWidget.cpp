#include "AethelnPOCOverlayWidget.h"

#include "Styling/CoreStyle.h"
#include "Widgets/Layout/SBorder.h"
#include "Widgets/Layout/SBox.h"
#include "Widgets/SBoxPanel.h"
#include "Widgets/SOverlay.h"
#include "Widgets/Text/STextBlock.h"

UAethelnPOCOverlayWidget::UAethelnPOCOverlayWidget(const FObjectInitializer& ObjectInitializer)
	: Super(ObjectInitializer)
{
	SetIsFocusable(false);
	SetVisibility(ESlateVisibility::HitTestInvisible);
}

TSharedRef<SWidget> UAethelnPOCOverlayWidget::RebuildWidget()
{
	return SNew(SOverlay)
		+ SOverlay::Slot()
		.HAlign(HAlign_Left)
		.VAlign(VAlign_Top)
		.Padding(FMargin(24.0f))
		[
			SNew(SBorder)
			.BorderImage(FCoreStyle::Get().GetBrush("ToolPanel.GroupBorder"))
			.BorderBackgroundColor(FLinearColor(0.02f, 0.025f, 0.035f, 0.88f))
			.Padding(FMargin(16.0f, 12.0f))
			[
				SNew(SBox)
				.WidthOverride(390.0f)
			[
				SNew(SVerticalBox)
				+ SVerticalBox::Slot()
				.AutoHeight()
				[
					SAssignNew(ModeStatus, STextBlock)
					.Text(FText::FromString(TEXT("RETICLE MODE")))
					.Font(FCoreStyle::GetDefaultFontStyle("Bold", 16))
					.ColorAndOpacity(FLinearColor(0.65f, 0.9f, 1.0f, 1.0f))
				]
				+ SVerticalBox::Slot()
				.AutoHeight()
				.Padding(0.0f, 4.0f, 0.0f, 0.0f)
				[
					SNew(STextBlock)
					.Text(FText::FromString(
						TEXT("WASD  Move    Mouse  Aim / Camera\n")
						TEXT("Left Alt  Toggle Cursor Mode\n")
						TEXT("Mouse Wheel  Camera Zoom / Shoulder / First Person\n")
						TEXT("Space  Jump   Shift  Sprint Forward (Standalone)\n")
						TEXT("LMB Primary / RMB Defense  Reserved (No Combat Yet)")))
					.Font(FCoreStyle::GetDefaultFontStyle("Bold", 14))
					.ColorAndOpacity(FLinearColor(0.95f, 0.97f, 1.0f, 1.0f))
				]
			]
			]
		]
		+ SOverlay::Slot()
		.HAlign(HAlign_Center)
		.VAlign(VAlign_Center)
		[
			SAssignNew(AimReticle, STextBlock)
			.Text(FText::FromString(TEXT("+")))
			.Font(FCoreStyle::GetDefaultFontStyle("Bold", 24))
			.ColorAndOpacity(FLinearColor(0.95f, 0.97f, 1.0f, 0.9f))
			.Visibility(EVisibility::HitTestInvisible)
		];
}

void UAethelnPOCOverlayWidget::SetControlMode(bool bReticleMode)
{
	if (AimReticle.IsValid())
	{
		AimReticle->SetVisibility(
			bReticleMode
				? EVisibility::HitTestInvisible
				: EVisibility::Collapsed);
	}
	if (ModeStatus.IsValid())
	{
		ModeStatus->SetText(FText::FromString(
			bReticleMode
				? TEXT("RETICLE MODE")
				: TEXT("CURSOR MODE - ALT OR CLICK VIEWPORT TO RETURN")));
	}
}
