<script setup lang="ts">
import { RouterView } from 'vue-router';
</script>

<template>
  <div class="app-root">
    <main class="app-main">
      <RouterView />
    </main>
  </div>
</template>

<style scoped>
.app-root {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}

.app-main {
  flex: 1;
  min-height: 0;
}
</style>
