import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router';
import AppView from './views/AppView.vue';
import CountryOverview from './views/CountryOverview.vue';

const routes: RouteRecordRaw[] = [
  { path: '/', component: AppView },
  { path: '/country/:countryCode', component: CountryOverview },
];

const router = createRouter({
  history: createWebHistory(import.meta.env.BASE_URL),
  routes,
});

export default router;
