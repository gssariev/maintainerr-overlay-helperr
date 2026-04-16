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
  let endpoint = '/api/collections/overlay-data';

  try {
    // Attempt the primary fetch
    let response = await this.client.get<MaintainerrCollection[]>(endpoint);

    return this.handleSuccess(response.data);

  } catch (err) {
    // Check for 404 to trigger fallback
    if (axios.isAxiosError(err) && err.response?.status === 404) {
      this.log.info('overlay-data endpoint not available, falling back to /api/collections');
      endpoint = '/api/collections';
      
      try {
        // Attempt the fallback fetch
        const fallbackResponse = await this.client.get<MaintainerrCollection[]>(endpoint);
        return this.handleSuccess(fallbackResponse.data);
      } catch (fallbackErr) {
        this.log.error('Failed to fetch Maintainerr collections on fallback endpoint.', fallbackErr);
        throw fallbackErr;
      }
    }

    // Handle all other errors from the initial fetch
    this.log.error('Failed to fetch Maintainerr collections.', err);
    throw err;
  }
}

// A small helper to keep the success logic DRY
private handleSuccess(data: MaintainerrCollection[]): MaintainerrCollection[] {
  this.log.info(`Fetched ${data.length} collection(s) from Maintainerr.`);
  return data;
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
