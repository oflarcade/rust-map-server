import { ref, watch } from 'vue';

const isDark = ref(localStorage.getItem('theme') === 'dark');

// Apply on init
if (isDark.value) document.documentElement.classList.add('dark');

export function useTheme() {
  function toggle() {
    isDark.value = !isDark.value;
    if (isDark.value) {
      document.documentElement.classList.add('dark');
      localStorage.setItem('theme', 'dark');
    } else {
      document.documentElement.classList.remove('dark');
      localStorage.setItem('theme', 'light');
    }
  }

  return { isDark, toggle };
}
