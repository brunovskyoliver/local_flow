//! Kit controls page code may use. Everything is re-exported from here so the pages don't name
//! GPUI Kit directly.
pub use gpui_kit::component::input::{Input, InputEvent as TextInputEvent, InputState};
pub use gpui_kit::component::input::{Textarea, TextareaState};
pub use gpui_kit::component::switch::Switch;
pub use gpui_kit::component::menu::{DropdownMenu, PopupMenu, PopupMenuItem, ContextMenuExt};
pub use gpui_kit::component::button::{Button, ButtonCustomVariant, ButtonVariants};
pub use gpui_kit::component::{Disableable, Sizable, Size as ControlSize, Side, WindowExt as FlowWindowExt, ActiveTheme};
pub use gpui_kit::component::popover::Popover;
pub use gpui_kit::component::dialog::{Dialog, AlertDialog};
pub use gpui_kit::component::slider::{Slider, SliderState, SliderEvent, SliderValue};
pub use gpui_kit::component::tooltip::Tooltip;
pub use gpui_kit::component::scroll::{Scrollbar, ScrollbarMode, ScrollableElement};
pub use gpui_kit::component::spinner::Spinner;
pub use gpui_kit::component::progress::Progress;
pub use gpui_kit::component::VirtualListScrollHandle;
pub use gpui_kit::component::{v_virtual_list, h_virtual_list};
pub use gpui_kit::component::calendar::{Calendar, CalendarEvent, CalendarState, Date as CalendarDate};

/// A calendar selection from `YYYY-MM-DD`; an unparsable text selects nothing.
pub fn calendar_date(text: &str) -> CalendarDate {
    CalendarDate::Single(text.parse().ok())
}
/// The selected day as `YYYY-MM-DD`.
pub fn calendar_text(date: &CalendarDate) -> Option<String> {
    date.start().map(|d| d.to_string())
}
