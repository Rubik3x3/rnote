// Imports
use crate::store::chrono_comp::StrokeLayer;
use rand::{RngExt, SeedableRng};
use rnote_compose::Style;
use rnote_compose::builders::PenPathBuilderType;
use rnote_compose::style::PressureCurve;
use rnote_compose::style::smooth::SmoothOptions;
use rnote_compose::style::textured::TexturedOptions;
use serde::{Deserialize, Serialize};

#[derive(
    Debug,
    Copy,
    Clone,
    Eq,
    PartialEq,
    Serialize,
    Deserialize,
    num_derive::FromPrimitive,
    num_derive::ToPrimitive,
)]
#[serde(rename = "brush_style")]
pub enum BrushStyle {
    #[serde(rename = "marker")]
    Marker = 0,
    #[serde(rename = "solid")]
    Solid,
    #[serde(rename = "textured")]
    Textured,
}

impl Default for BrushStyle {
    fn default() -> Self {
        Self::Solid
    }
}

impl TryFrom<u32> for BrushStyle {
    type Error = anyhow::Error;

    fn try_from(value: u32) -> Result<Self, Self::Error> {
        num_traits::FromPrimitive::from_u32(value).ok_or_else(|| {
            anyhow::anyhow!("BrushStyle try_from::<u32>() for value {} failed", value)
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename = "marker_options")]
pub struct MarkerOptions(SmoothOptions);

impl Default for MarkerOptions {
    fn default() -> Self {
        let mut options = SmoothOptions::default();
        options.pressure_curve = PressureCurve::Const;
        options.stroke_width = 12.0;

        Self(options)
    }
}

impl std::ops::Deref for MarkerOptions {
    type Target = SmoothOptions;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for MarkerOptions {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename = "solid_options")]
pub struct SolidOptions(SmoothOptions);

impl Default for SolidOptions {
    fn default() -> Self {
        Self(SmoothOptions::default())
    }
}

impl std::ops::Deref for SolidOptions {
    type Target = SmoothOptions;

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl std::ops::DerefMut for SolidOptions {
    fn deref_mut(&mut self) -> &mut Self::Target {
        &mut self.0
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default, rename = "brush_config")]
pub struct BrushConfig {
    #[serde(rename = "builder_type")]
    pub builder_type: PenPathBuilderType,
    #[serde(rename = "style")]
    pub style: BrushStyle,
    #[serde(rename = "marker_options")]
    pub marker_options: MarkerOptions,
    #[serde(rename = "solid_options")]
    pub solid_options: SolidOptions,
    #[serde(rename = "textured_options")]
    pub textured_options: TexturedOptions,
    /// Turn strokes into ideal shapes when the pen is held still at their end.
    #[serde(rename = "shape_recognition")]
    pub shape_recognition: bool,
    /// How long the pen must be held still before the stroke is recognized, in milliseconds.
    #[serde(rename = "shape_recognition_delay_ms")]
    pub shape_recognition_delay_ms: u32,
    /// How much a circle may be squashed and still become a circle instead of an ellipse, from 0 to 1.
    #[serde(rename = "shape_circle_tolerance")]
    pub shape_circle_tolerance: f64,
}

impl Default for BrushConfig {
    fn default() -> Self {
        Self {
            builder_type: PenPathBuilderType::default(),
            style: BrushStyle::default(),
            marker_options: MarkerOptions::default(),
            solid_options: SolidOptions::default(),
            textured_options: TexturedOptions::default(),
            shape_recognition: true,
            shape_recognition_delay_ms: Self::SHAPE_RECOGNITION_DELAY_DEFAULT,
            shape_circle_tolerance:
                rnote_compose::recognition::RecognitionOptions::CIRCLE_TOLERANCE_DEFAULT,
        }
    }
}

impl BrushConfig {
    pub const STROKE_WIDTH_MIN: f64 = 0.1;
    pub const STROKE_WIDTH_MAX: f64 = 500.0;
    pub const SHAPE_RECOGNITION_DELAY_DEFAULT: u32 = 500;
    pub const SHAPE_RECOGNITION_DELAY_MIN: u32 = 200;
    pub const SHAPE_RECOGNITION_DELAY_MAX: u32 = 2000;
    pub const SHAPE_CIRCLE_TOLERANCE_MAX: f64 = 0.5;

    pub(crate) fn layer_for_current_options(&self) -> StrokeLayer {
        match &self.style {
            BrushStyle::Marker => StrokeLayer::Highlighter,
            BrushStyle::Solid | BrushStyle::Textured => StrokeLayer::UserLayer(0),
        }
    }

    /// A new seed for new shapes
    pub(crate) fn new_style_seeds(&mut self) {
        let seed = Some(rand_pcg::Pcg64::from_rng(&mut rand::rng()).random());
        self.textured_options.seed = seed;
    }

    pub(crate) fn style_for_current_options(&self) -> Style {
        match &self.style {
            BrushStyle::Marker => {
                let MarkerOptions(options) = self.marker_options.clone();

                Style::Smooth(options)
            }
            BrushStyle::Solid => {
                let SolidOptions(options) = self.solid_options.clone();

                Style::Smooth(options)
            }
            BrushStyle::Textured => {
                let options = self.textured_options.clone();

                Style::Textured(options)
            }
        }
    }
}
