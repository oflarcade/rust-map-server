import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router';
import AppView from './views/AppView.vue';

const routes: RouteRecordRaw[] = [
  { path: '/', component: AppView },
];

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
});

export default router;
