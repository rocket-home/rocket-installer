// Adapter: единая точка UI-функций TUI. Все модули rocket-control импортируют
// clack-функции только отсюда — тесты подменяют модуль через mock.module,
// одна точка перехвата заменяет все интерактивные взаимодействия.
export {
  intro,
  outro,
  cancel,
  select,
  multiselect,
  confirm,
  text,
  note,
  log,
  spinner,
  isCancel,
} from "@clack/prompts";
