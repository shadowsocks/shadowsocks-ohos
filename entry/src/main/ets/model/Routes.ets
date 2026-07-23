/*******************************************************************************
 *                                                                             *
 *  Copyright (C) 2026 by Max Lv <max.c.lv@gmail.com>                          *
 *                                                                             *
 *  This program is free software: you can redistribute it and/or modify       *
 *  it under the terms of the GNU General Public License as published by       *
 *  the Free Software Foundation, either version 3 of the License, or          *
 *  (at your option) any later version.                                        *
 *                                                                             *
 *  This program is distributed in the hope that it will be useful,            *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of             *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              *
 *  GNU General Public License for more details.                               *
 *                                                                             *
 *  You should have received a copy of the GNU General Public License          *
 *  along with this program. If not, see <http://www.gnu.org/licenses/>.       *
 *                                                                             *
 *******************************************************************************/

/**
 * Policy routes, mirroring shadowsocks-android's `Acl` constants. Every route
 * except `all` maps to an ACL file shipped as a rawfile resource
 * (`resources/rawfile/acl/<file>`), deployed to the app files dir at VPN
 * start and handed to the core via the top-level `acl` config field.
 */
export const ROUTE_ALL: string = 'all';
export const ROUTE_BYPASS_LAN: string = 'bypass-lan';
export const ROUTE_BYPASS_CHINA: string = 'bypass-china';
export const ROUTE_BYPASS_LAN_CHINA: string = 'bypass-lan-china';
export const ROUTE_GFWLIST: string = 'gfwlist';
export const ROUTE_CHINA_LIST: string = 'china-list';

export const ALL_ROUTES: string[] = [
  ROUTE_ALL,
  ROUTE_BYPASS_LAN,
  ROUTE_BYPASS_CHINA,
  ROUTE_BYPASS_LAN_CHINA,
  ROUTE_GFWLIST,
  ROUTE_CHINA_LIST,
];

/** Rawfile ACL name for a route, or '' when the route needs no ACL. */
export function aclFileForRoute(route: string): string {
  switch (route) {
    case ROUTE_BYPASS_LAN:
      return 'bypass-lan.acl';
    case ROUTE_BYPASS_CHINA:
      return 'bypass-china.acl';
    case ROUTE_BYPASS_LAN_CHINA:
      return 'bypass-lan-china.acl';
    case ROUTE_GFWLIST:
      return 'gfwlist.acl';
    case ROUTE_CHINA_LIST:
      return 'china-list.acl';
    default:
      return '';
  }
}

export function isValidRoute(route: string): boolean {
  return ALL_ROUTES.indexOf(route) >= 0;
}
