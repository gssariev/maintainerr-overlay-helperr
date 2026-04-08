import axios, { AxiosInstance } from 'axios';
import { MaintainerrCollection } from '../types/maintainerr';
import { LogService } from './LogService';

export class MaintainerrService {
  private client: AxiosInstance;

  constructor(
    private baseUrl: string,
    private log: LogService,
  ) {
    this.client = axios.create({ baseURL: baseUrl, timeout: 30000 });
  }

  updateBaseUrl(url: string): void {
    this.baseUrl = url;
    this.client.defaults.baseURL = url;
  }

  async testConnection(): Promise<boolean> {
    try {
      await this.client.get('/api/media-server/');
      return true;
    } catch {
      return false;
    }
  }

  async getCollections(): Promise<MaintainerrCollection[]> {
    try {
      // Try the dedicated overlay-data endpoint first (Maintainerr >= 3.4.0)
      const { data } = await this.client.get<MaintainerrCollection[]>('/api/collections/overlay-data');
      this.log.info(`Fetched ${data.length} collection(s) from Maintainerr.`);
      return data;
    } catch (err) {
      // Fall back to the legacy endpoint (Maintainerr <= 3.3.x)
      if (axios.isAxiosError(err) && err.response?.status === 404) {
        this.log.info('overlay-data endpoint not available, falling back to /api/collections');
        try {
          const { data } = await this.client.get<MaintainerrCollection[]>('/api/collections');
          this.log.info(`Fetched ${data.length} collection(s) from Maintainerr.`);
          return data;
        } catch (fallbackErr) {
          this.log.error(`Failed to fetch Maintainerr collections: ${fallbackErr}`);
          throw fallbackErr;
        }
      }
      this.log.error(`Failed to fetch Maintainerr collections: ${err}`);
      throw err;
    }
  }

  async getLibraryCollections(
    libraryId: string | number,
  ): Promise<{ ratingKey: string; title: string }[]> {
    try {
      const { data } = await this.client.get(
        `/api/media-server/library/${libraryId}/collections`,
      );
      const raw: unknown[] = data ?? [];
      if (raw.length > 0) {
        this.log.debug(`getLibraryCollections sample: ${JSON.stringify(raw[0])}`);
      }
      // Normalise: accept ratingKey, key (/library/metadata/{id}/…), or id
      return raw.map((item: any) => {
        let ratingKey: string = item.ratingKey ?? '';
        if (!ratingKey && item.key) {
          const m = String(item.key).match(/\/library\/metadata\/(\d+)/);
          if (m) ratingKey = m[1];
        }
        if (!ratingKey && item.id != null) {
          ratingKey = String(item.id);
        }
        return { ratingKey, title: item.title ?? '' };
      });
    } catch (err) {
      if (axios.isAxiosError(err) && err.response?.status === 404) {
        this.log.warn(`Library ${libraryId} collections endpoint returned 404.`);
        return [];
      }
      this.log.warn(`Failed to fetch library ${libraryId} collections: ${err}`);
      return [];
    }
  }
}
