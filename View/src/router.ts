import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router';
import TileInspector from './views/TileInspector.vue';

const routes: RouteRecordRaw[] = [
  { path: '/', redirect: '/inspector' },
  { path: '/inspector', component: TileInspector },
];

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
});

export default router;
