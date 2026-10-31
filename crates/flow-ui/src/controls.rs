//! Kit controls page code may use. Everything is re-exported from here so the pages don't name
//! GPUI Kit directly.
pub use gpui_kit::component::input::{Input, InputEvent as TextInputEvent, InputState};
pub use gpui_kit::component::switch::Switch;
pub use gpui_kit::component::menu::{DropdownMenu, PopupMenu, PopupMenuItem, ContextMenuExt};
pub use gpui_kit::component::button::{Button, ButtonVariants};
pub use gpui_kit::component::{Disableable, Sizable, Size as ControlSize, Side, WindowExt as FlowWindowExt, ActiveTheme};
pub use gpui_kit::component::popover::Popover;
pub use gpui_kit::component::dialog::{Dialog, AlertDialog};
pub use gpui_kit::component::slider::{Slider, SliderState, SliderEvent, SliderValue};
pub use gpui_kit::component::tooltip::Tooltip;
pub use gpui_kit::component::scroll::{Scrollbar, ScrollableElement};
pub use gpui_kit::component::spinner::Spinner;
pub use gpui_kit::component::progress::Progress;
pub use gpui_kit::component::VirtualListScrollHandle;
pub use gpui_kit::component::{v_virtual_list, h_virtual_list};
